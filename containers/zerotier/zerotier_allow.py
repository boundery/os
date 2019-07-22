import os
import sys
import time
import re
from zerotier import zt_get, zt_post

def stderr(msg):
    print(msg, file = sys.stderr)
    sys.stderr.flush()

if len(sys.argv) < 1:
    stderr("Usage: zerotier_allow.py <network name>")
    exit(-1)
netname = sys.argv[1]

#Wait for the daemon, and get our hostid.
hostid = None
while True:
    status = zt_get("status")
    if status and status["online"]:
        hostid = status["address"]
        break
    stderr("Waiting for zerotier-one to start")
    time.sleep(5)
stderr("Got host id: %s" % hostid)

netid = None
adhocid = "ff05390539000000"

#Join the adhoc network.
zt_post("network/%s" % adhocid, {})

#Check to see if network is already there.
networks = zt_get("controller/network")
for id in networks:
    net = zt_get("controller/network/" + id)
    if net["name"] == netname:
        netid = net["id"]
        stderr("Got network id: %s" % netid)
        break

#XXX Would be cool to use 100.64.0.0/10 subnets here, but that is broken in ZT:
#    https://github.com/zerotier/ZeroTierOne/issues/675
#    If we do that, linux/windows/mac need to "allowGlobal" too.
if not netid: #Create the network
    stderr("Network %s doesn't exist, creating" % netname)
    newnet = {
        'name': netname,
        'multicastLimit': 16,
        'mtu': 2800,
        'v6AssignMode': {'rfc4193': False, 'zt': False, '6plane': True},
        'v4AssignMode': {'zt': True},
        'tags': [],
        'private': True,
        'ipAssignmentPools': [{
            'ipRangeEnd': '172.18.3.254',
            'ipRangeStart': '172.18.2.1'
        }],
        'enableBroadcast': True,
        'routes': [{'via': None, 'target': '172.18.0.0/22'}],
    }
    net = zt_post("controller/network/%s______" % hostid, newnet)
    netid = net["id"]
    stderr("Created network id: %s" % netid)

#Join the network.  This is harmless if we're already a member.
zt_post("network/%s" % netid, {})

#Poll until our request to join shows up.
member = None
while True:
    member = zt_get("controller/network/%s/member/%s" % (netid, hostid))
    if member:
        break
    stderr("Waiting to join network")
    time.sleep(1)

#Now authorize ourselves, if we're not already.
if member["authorized"] != True:
    stderr("Authorizing")
    newmember = {
        'authorized': True,
        'activeBridge': True,
        'ipAssignments': [ '172.18.0.1' ],
    }
    zt_post("controller/network/%s/member/%s" % (netid, hostid),
            newmember)

#Wait for interfaces to come up
ztif = None
bootstrap_ipv6 = None
while True:
    net = zt_get("network/%s" % netid)
    if net["status"] == "OK":
        ztif = net["portDeviceName"]
        break
    stderr("Waiting for %s interface to appear" % netname)
    time.sleep(1)
while True:
    net = zt_get("network/%s" % adhocid)
    if net["status"] == "OK":
        m = None
        for addr in net["assignedAddresses"]:
            m = re.fullmatch("(fc[0-9a-f:]+)/40", addr)
            if m:
                break
        if m:
            bootstrap_ipv6 = m.group(1)
            break
        # bad bad bad
        stderr("Bootstrap interface %s exists " +
               "but does not have a suitable address." % adhocid)
        stderr("assignedAddresses: %s" % net["assignedAddresses"])
    stderr("Waiting for bootstrap interface to appear")
    time.sleep(1)

stderr("Private interface: %s" % ztif)
stderr("Bootstrop address: %s" % bootstrap_ipv6)
print("%s %s" % (ztif, bootstrap_ipv6))
