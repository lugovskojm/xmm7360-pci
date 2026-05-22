#!/usr/bin/env python3

import configargparse
from pyroute2 import IPRoute
from os.path import join, abspath, dirname
import uuid
import socket
import struct
import dbus
import sys
import time
import subprocess
import signal
import atexit

import rpc
import logging
logging.basicConfig(level=logging.DEBUG)

parser = configargparse.ArgumentParser(
    description='Hacky tool to bring up XMM7x60 modem',
    default_config_files=[
        '/etc/xmm7360',
        join(dirname(abspath(__file__)), '..', 'xmm7360.ini')
    ],
)

parser.add_argument('-c', '--conf', is_config_file=True)
parser.add_argument('-a', '--apn', required=True, help="Network provider APN")
parser.add_argument('-n', '--nodefaultroute', action="store_true",
                    help="Don't install modem as default route for IP traffic")
parser.add_argument('-m', '--metric', type=int, default=1000,
                    help="Metric for default route (higher is lower priority)")
parser.add_argument('-t', '--ip-fetch-timeout', type=int, default=1,
                    help="Retry interval in seconds when getting IP config")
parser.add_argument('-r', '--noresolv', action="store_true",
                    help="Don't add modem-provided DNS servers to system resolver")
parser.add_argument('-d', '--dbus', action="store_true",
                    help="Activate Networkmanager Connection via DBUS")

cfg, unknown = parser.parse_known_args()

r = None
try:
    r = rpc.XMMRPC()
except Exception as ex:
    logging.error(ex)
    exit()

ipr = IPRoute()
IFACE = 'wwan0'
_dns_applied = False


def _ip(*args, check=False):
    cmd = ['ip'] + list(args)
    logging.debug("exec: %s", ' '.join(cmd))
    return subprocess.run(
        cmd,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )


def _run_quiet(*args):
    logging.debug("exec: %s", ' '.join(args))
    return subprocess.run(
        list(args),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )


def _clean_dns(lst):
    out = []
    for d in (lst or []):
        if d is None:
            continue
        s = str(d).strip()
        if not s or s in ('0.0.0.0', '::', 'None'):
            continue
        out.append(str(d))
    return out


def _apply_resolved_dns(iface, dns_list):
    global _dns_applied
    if not dns_list:
        logging.info("No DNS servers to apply")
        return

    if cfg.noresolv:
        logging.info("Skipping DNS apply because --noresolv was specified")
        return

    check = _run_quiet('resolvectl', 'status')
    if check.returncode != 0:
        logging.warning("systemd-resolved/resolvectl not available, skipping DNS apply")
        return

    res = _run_quiet('resolvectl', 'dns', iface, *dns_list)
    if res.returncode != 0:
        logging.warning("Failed to apply DNS via resolvectl: %s", res.stderr.strip())
        return

    res = _run_quiet('resolvectl', 'domain', iface, '~.')
    if res.returncode != 0:
        logging.warning("Failed to set DNS domain route via resolvectl: %s", res.stderr.strip())

    res = _run_quiet('resolvectl', 'default-route', iface, 'true')
    if res.returncode != 0:
        logging.warning("Failed to set default DNS route via resolvectl: %s", res.stderr.strip())

    _dns_applied = True
    logging.info("Applied DNS via systemd-resolved on %s: %s", iface, ', '.join(dns_list))


def _revert_resolved_dns():
    if not _dns_applied:
        return
    res = _run_quiet('resolvectl', 'revert', IFACE)
    if res.returncode != 0:
        logging.warning("Failed to revert DNS on %s: %s", IFACE, res.stderr.strip())
    else:
        logging.info("Reverted DNS settings on %s", IFACE)


def _shutdown(signum=None, frame=None):
    _revert_resolved_dns()
    sys.exit(0)


atexit.register(_revert_resolved_dns)
signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)

r.execute('UtaMsSmsInit')
r.execute('UtaMsCbsInit')
r.execute('UtaMsNetOpen')
r.execute('UtaMsCallCsInit')
r.execute('UtaMsCallPsInitialize')
r.execute('UtaMsSsInit')
r.execute('UtaMsSimOpenReq')

rpc.do_fcc_unlock(r)
rpc.UtaModeSet(r, 1)

r.execute('UtaMsCallPsAttachApnConfigReq',
          rpc.pack_UtaMsCallPsAttachApnConfigReq(cfg.apn), is_async=True)

attach = r.execute('UtaMsNetAttachReq',
                   rpc.pack_UtaMsNetAttachReq(), is_async=True)
_, status = rpc.unpack('nn', attach['body'])

if status == 0xffffffff:
    logging.info("Attach failed - waiting to see if we just weren't ready")

while not r.attach_allowed:
    r.pump()

attach = r.execute('UtaMsNetAttachReq',
                   rpc.pack_UtaMsNetAttachReq(), is_async=True)
_, status = rpc.unpack('nn', attach['body'])

if status == 0xffffffff:
    logging.error("Attach failed again, giving up")
    sys.exit(1)

while True:
    ip_addr, dns_values = rpc.get_ip(r)
    if ip_addr is not None:
        break
    interval = cfg.ip_fetch_timeout
    logging.info(f"IP address couldn't be fetched, waiting {interval} seconds")
    time.sleep(interval)

logging.info("IP address: " + str(ip_addr))

dns_values['v4'] = _clean_dns(dns_values.get('v4'))
dns_values['v6'] = _clean_dns(dns_values.get('v6'))
all_dns = dns_values['v4'] + dns_values['v6']

if all_dns:
    logging.info("DNS server(s): " + ', '.join(all_dns))
else:
    logging.info("DNS server(s): (none reported)")

_ip('link', 'set', 'dev', IFACE, 'up')
_ip('addr', 'flush', 'dev', IFACE)
_ip('route', 'flush', 'dev', IFACE)

res = _ip('addr', 'add', f'{ip_addr}/32', 'peer', '0.0.0.0/0', 'dev', IFACE)
if res.returncode != 0 and 'exists' not in (res.stderr or ''):
    logging.warning("ip addr add failed: %s", res.stderr.strip())

if not cfg.nodefaultroute:
    res = _ip('route', 'replace', 'default', 'dev', IFACE,
              'scope', 'link', 'metric', str(cfg.metric))
    if res.returncode != 0:
        logging.warning("ip route replace default failed: %s", res.stderr.strip())

_apply_resolved_dns(IFACE, all_dns)

pscr = r.execute('UtaMsCallPsConnectReq',
                 rpc.pack_UtaMsCallPsConnectReq(), is_async=True)
dcr = r.execute('UtaRPCPsConnectToDatachannelReq',
                rpc.pack_UtaRPCPsConnectToDatachannelReq())

csr_req = pscr['body'][:-6] + dcr['body'] + b'\x02\x04\0\0\0\0'

try:
    r.execute('UtaRPCPSConnectSetupReq', csr_req)
except Exception as e:
    logging.warning("UtaRPCPSConnectSetupReq failed: %s (continuing anyway)", e)

if not cfg.dbus:
    logging.info("PDP session established, holding (no dbus mode). Send SIGTERM/SIGINT to tear down.")
    while True:
        try:
            time.sleep(3600)
        except KeyboardInterrupt:
            sys.exit(0)

myconnection = None
system_bus = dbus.SystemBus()
service_name = "org.freedesktop.NetworkManager"
proxy = system_bus.get_object(
    service_name, "/org/freedesktop/NetworkManager/Settings")
dproxy = system_bus.get_object(service_name, "/org/freedesktop/NetworkManager")
settings = dbus.Interface(proxy, "org.freedesktop.NetworkManager.Settings")
manager = dbus.Interface(dproxy, "org.freedesktop.NetworkManager")

def dottedQuadToNum(ip):
    return struct.unpack('I', socket.inet_aton(ip))[0]

for c in settings.ListConnections():
    c_proxy = system_bus.get_object(service_name, c)
    con = dbus.Interface(c_proxy,
                         "org.freedesktop.NetworkManager.Settings.Connection")
    settings_dict = con.GetSettings()
    if settings_dict['connection']['type'] == 'gsm':
        myconnection = c
        break

if myconnection is None:
    print("No gsm connection found, giving up")
    sys.exit(1)

manager.ActivateConnection(myconnection,
                           "/org/freedesktop/NetworkManager/Devices/0", "/")
while True:
    r.pump()
