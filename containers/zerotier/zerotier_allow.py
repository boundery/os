#!/usr/bin/env python3

import requests
import json
import os
import sys
import time
import subprocess

if len(sys.argv) < 1:
    print("Usage: zerotier_allow.py <network name>")
    exit(-1)
netname = sys.argv[1]

def zt_do(path, data = None):
    headers = { 'Connection': 'close',
                'Content-Type': 'application/json',
                'Authorization': 'Bearer %s' % os.getenv("ZEROTIER_TOKEN") }

    url = "https://my.zerotier.com/api/%s" % path

    if data:
        r = requests.post(url, headers = headers, data = json.dumps(data))
    else:
        r = requests.get(url, headers = headers)

    if r.status_code == 200 and len(r.text) != 0:
        print("'%s'" % r.text)
        return r.json()
    else:
        return None

def zt_get(path):
    return zt_do(path)
def zt_post(path, data):
    return zt_do(path, data)

netid = None

#Check to see if it is already there.
networks = zt_get("network")
for net in networks:
    if net["config"]["name"] == netname:
        netid = net["id"]
        break

#XXX Would be cool to use 100.64.0.0/10 subnets here, but that is broken in ZT:
#    https://github.com/zerotier/ZeroTierOne/issues/675
#    If we do that, linux/windows/mac need to "allowGlobal" too.
if not netid: #Create the network
    print("Network %s doesn't exist, creating." % netname)
    newnet = { 'description': 'Private network for internal services',
               'config': { 'name': netname, 'multicastLimit': 0, 'mtu': 2800,
                           'v6AssignMode': {'rfc4193': False, 'zt': False, '6plane': True},
                           'v4AssignMode': {'zt': True},
                           'tags': [], 'private': True,
                           'ipAssignmentPools': [{'ipRangeEnd': '172.16.31.254', 'ipRangeStart': '172.16.28.1'}],
                           'enableBroadcast': True,
                           'routes': [{'via': None, 'target': '172.16.28.0/22'}]
                         }
             }
    net = zt_post("network", newnet)
    netid = net["id"]
    print("Created network id is %s" % netid)

#Wait for the daemon, and get our hostid.
hostid = None
while not hostid:
    status = subprocess.getoutput("/usr/sbin/zerotier-cli status")
    if status.startswith("200 "):
        hostid = status.split()[2]
        print("Got hostid: %s" % hostid)
    time.sleep(1)

#Join the network.  This is harmless if we're already a member.
newjoin = os.system("/usr/sbin/zerotier-cli join %s" % netid) == 0

#Poll until our request to join shows up.
member = None
pollcount = 0
while not member:
    member = zt_get("network/%s/member/%s" % (netid, hostid))
    time.sleep(5)
    pollcount += 1
    if pollcount > 10:
        raise Exception("Timed out waiting for member to show up")

#Now authorize ourselves, if we're not already.
#XXX Need to handle if there is already a "private" member with this IP, from
#    a previous run.
if member["config"]["authorized"] != True:
    print("Not authorized, authorizing with ZT Central")
    newmember = {}
    newmember["config"] = {}
    newmember["config"]["authorized"] = True
    newmember["config"]["activeBridge"] = True
    newmember["name"] = "services"
    #ZT Central autosetting the IPv4 addr is busted, so set it here.
    newmember["config"]["ipAssignments"] = [ "172.16.28.1" ]
    zt_post("network/%s/member/%s" % (netid, hostid),
            newmember)

#XXX Poll here checking if our local daemon is authorized and connected, if
#    that doesn't happen in a reasonable amount of time, blow up, and the
#    outer shell script can retry.
