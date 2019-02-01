#!/usr/bin/env python3

import requests
import json
import os
import sys
import time

if len(sys.argv) < 1:
    print("Usage: zerotier_allow.py <network name>")
    exit(-1)
netname = sys.argv[1]

# Get the "secret" authtoken for API authentication
authtoken = None
while True:
    try:
        with open("/var/lib/zerotier-one/authtoken.secret") as f:
            # XXX is there a chance of a race with zerotier startup?
            authtoken = f.read().strip()
    except FileNotFoundError:
        pass
    if authtoken:
        break
    print("Waiting for zerotier authtoken to be created")
    time.sleep(1)

def zt_do(path, data = None):
    headers = { 'Connection': 'close',
                'Content-Type': 'application/json',
                'X-ZT1-Auth': authtoken }

    url = "http://localhost:9993/%s" % path

    try:
        if data:
            r = requests.post(url, headers = headers, data = json.dumps(data))
        else:
            r = requests.get(url, headers = headers)
    except requests.exceptions.ConnectionError:
	# Fail soft if daemon isn't running (yet)
        return None

    if r.status_code == 200 and len(r.text) != 0:
        #print("'%s'" % r.text)
        return r.json()
    else:
        return None

def zt_get(path):
    return zt_do(path)
def zt_post(path, data):
    return zt_do(path, data)

#Wait for the daemon, and get our hostid.
hostid = None
while True:
    status = zt_get("status")
    if status and status["online"]:
        hostid = status["address"]
        break
    print("Waiting for zerotier-one to start")
    time.sleep(5)
print("Got host id: %s" % hostid)

netid = None

#Check to see if network is already there.
networks = zt_get("controller/network")
for id in networks:
    net = zt_get("controller/network/" + id)
    if net["name"] == netname:
        netid = net["id"]
        print("Got network id: %s" % netid)
        break

#XXX Would be cool to use 100.64.0.0/10 subnets here, but that is broken in ZT:
#    https://github.com/zerotier/ZeroTierOne/issues/675
#    If we do that, linux/windows/mac need to "allowGlobal" too.
if not netid: #Create the network
    print("Network %s doesn't exist, creating" % netname)
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
    print("Created network id: %s" % netid)

    # (Pre)authorize additional hosts, for devel bring-up only
    for ahost in os.getenv("ZEROTIER_AUTHORIZED_HOSTS", "").split():
        print("Authorizing host %s" % ahost)
        zt_post("controller/network/%s/member/%s" % (netid, ahost),
                {'authorized': True, 'activeBridge': True})

#Join the network.  This is harmless if we're already a member.
newjoin = os.system("/usr/sbin/zerotier-cli join %s" % netid) == 0

#Poll until our request to join shows up.
member = None
while True:
    member = zt_get("controller/network/%s/member/%s" % (netid, hostid))
    if member:
        break
    print("Waiting to join network")
    time.sleep(1)

#Now authorize ourselves, if we're not already.
if member["authorized"] != True:
    print("Authorizing")
    newmember = {
        'authorized': True,
        'activeBridge': True,
        'ipAssignments': [ '172.18.0.1' ],
    }
    zt_post("controller/network/%s/member/%s" % (netid, hostid),
            newmember)

#XXX Poll here checking if our local daemon is authorized and connected, if
#    that doesn't happen in a reasonable amount of time, blow up, and the
#    outer shell script can retry.
