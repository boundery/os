import argparse, json, time, requests, base64
from hkdf import hkdf_extract, hkdf_expand

USERINFO_POLL_INTERVAL=5

parser = argparse.ArgumentParser(description="Register with the central server")
parser.add_argument("centralurl", help="URL to central")
parser.add_argument("bootstrap_ipv6", help="Bootstrap IPv6 address")
args = parser.parse_args()

centralurl = args.centralurl
bootstrap_ipv6 = args.bootstrap_ipv6

with open('/pairingkey', 'rb') as f:
    pairing_key = f.read()

def get_subkey(keyname, salt = None):
    if type(keyname) == str:
        keyname = keyname.encode()
    return hkdf_expand(hkdf_extract(salt, pairing_key), keyname, 32)

print("Trying to register")
pairing_id = base64.standard_b64encode(get_subkey('pairing_id'))
while True:
    req = requests.post(centralurl + '/api/v1/register_server/',
                            data = { "PAIRING_ID": pairing_id,
                                         "BOOTSTRAP_IPV6": bootstrap_ipv6 })
    if req.status_code == 200:
        apikey = req.json()['apikey']
        break
    time.sleep(USERINFO_POLL_INTERVAL)

with open('/apikey', 'w') as f:
    f.write(apikey)

print("Registered successfully")
