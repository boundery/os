import sys
from libnacl.secret import SecretBox
from hkdf import hkdf_extract, hkdf_expand
from zerotier import zt_get, zt_post

if len(sys.argv) < 1:
    print("Usage: handle_client.py <network name>", file=sys.stderr)
    exit(-1)
netname = sys.argv[1]

with open('/pairingkey', 'rb') as f:
    pairing_key = f.read()

def get_subkey(keyname, salt = None):
    if type(keyname) == str:
        keyname = keyname.encode()
    return hkdf_expand(hkdf_extract(salt, pairing_key), keyname, 32)

#Get netid for private network.
netid = None
networks = zt_get("controller/network")
for id in networks:
    net = zt_get("controller/network/" + id)
    if net["name"] == netname:
        netid = net["id"]
        print("Got network id: %s" % netid, file=sys.stderr)
        break

#Get the client's hostid and decrypt it.
to_read = int.from_bytes(sys.stdin.buffer.read(1), byteorder='big')
hkdf_salt=b''
while len(hkdf_salt) < to_read:
    hkdf_salt += sys.stdin.buffer.read(to_read - len(hkdf_salt))
to_read = int.from_bytes(sys.stdin.buffer.read(1), byteorder='big')
ciphertext=b''
while len(ciphertext) < to_read:
    ciphertext += sys.stdin.buffer.read(to_read - len(ciphertext))

to_server_key = get_subkey("to_server", hkdf_salt)
hostid = SecretBox(to_server_key).decrypt(ciphertext).decode()
print("Get hostid %s from client" % hostid, file=sys.stderr)

#Now authorize the client
print("Authorizing", file=sys.stderr)
zt_post("controller/network/%s/member/%s" % (netid, hostid),
            { 'authorized': True, 'activeBridge': True })

#Encrypt and send back the network id.
from_server_key = get_subkey("from_server", hkdf_salt)
ciphertext = SecretBox(from_server_key).encrypt(netid.encode())
assert(len(ciphertext) < 256)
sys.stdout.buffer.write(len(ciphertext).to_bytes(1, byteorder='big') + ciphertext)
print("Finished", file=sys.stderr)
