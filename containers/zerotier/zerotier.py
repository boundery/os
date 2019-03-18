import requests
import json
import sys
import time

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
        if data is not None:
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
