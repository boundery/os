import socketserver
import sys, os, io, argparse, json, time, docker, requests, socket
import threading, html, traceback

#VIA INTERNET:
#curl_https_to_dev_null:              0m25.746s
#with_unxz:                           0m46.426s
#without_unxz_to_docker:              5m21.534s
#with_unxz_to_docker:                 4m55.459s
#
#appc, unxz in docker, docker.py BS=128K: 4m31s
#appc, unxz in docker, docker.py BS=None: <failed>
#appc, unxz in docker, docker.py BS=1M: 4m37s
#
# docker pull:                        4m15.088s

# Format: {"cmd": "command", "args": ["arg1", ...]}

DYNDNS_INTERVAL=180

parser = argparse.ArgumentParser(description="Install and run apps")
parser.add_argument("centralurl", help="URL to central")
parser.add_argument("apikey", help="API key for central")
parser.add_argument("domain", help="User's domain name")
args = parser.parse_args()

centralurl = args.centralurl
api_key = args.apikey
domain = args.domain

init_complete = threading.Event()

BUF_SIZE=128*1024

inflight = {}

#We replace docker_load here, since it has a short timeout, which means
# it can only load very small images.
assert(docker.version.startswith('1.9'))
def docker_load(dclient, stream):
    res = dclient._post(dclient._url("/images/load"),
                        data=stream, timeout=(30, 600))
    dclient._raise_for_status(res)

def install_app(app):
    try:
        dclient = docker.from_env()

        inflight[app] = "Downloading app" ; print(inflight[app])
        r = requests.get(centralurl + "static/apps/" + app + ".tar.xz",
                         stream=True)
        docker_load(dclient, r.iter_content(chunk_size = BUF_SIZE))
        r.close()
        with open('/appscripts/' + app + ".tar.xz", "wb") as f:
            f.write('') #XXX Even worse HACK!

        inflight[app] = "Installing app" ; print(inflight[app])
        r = requests.get(centralurl + "static/apps/start" + app)
        with open('/appscripts/start' + app, 'wb') as f:
            f.write(r.content)
        r.close()
        #XXX Someone needs to start the app.
        inflight[app] = "Application installed successfully"  ; print(inflight[app])
    except:
        print("Exception: %s %s %s" % sys.exc_info())
        print(traceback.format_exc())
        inflight[app] = "ERROR %s %s" % (html.escape(str(sys.exc_info()[0])),
                                         html.escape(str(sys.exc_info()[1])))

class AppsTCPHandler(socketserver.StreamRequestHandler):
    def handle(self):
        req = json.loads(self.rfile.readline().strip().decode())
        cmd = req["cmd"]
        args = req["args"]

        print("handle: %s %s" % (cmd, args))

        #XXX Exceptions.
        if cmd == "install":
            #( date; bash /mnt/sda1/appc '{"cmd":"install","args":["email"]}'; date ) >> /tmp/times
            #XXX Check to see if already installed.
            app = args[0]
            if app in inflight:
                self.wfile.write(inflight[app].encode())
            else:
                threading.Thread(target=install_app, args=(app,), daemon=True).start()
                self.wfile.write("Starting app install\n".encode())
        else:
            self.wfile.write("unknown command\n".encode())

def dnsd_cmd(cmd):
    print("dnsd_cmd: %s" % cmd)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("dnsd", 54))
    s.sendall(cmd.encode())
    resp = s.recv(1024)
    s.close()
    return resp.decode()

def update_dyndns():
    old_ip = "0.0.0.0"
    while True:
        #Ping dyndns every DYNDNS_INTERVAL seconds
        try:
            r = requests.get(centralurl + "api/v1/update_ip/?IP=%s&APIKEY=%s" %
                             (old_ip, api_key))
            if r.status_code == 200:
                ip = r.text
                r.close()

                if ip != "nop" and ip != old_ip:
                    print("IP changed: %s -> %s" % (old_ip, ip))
                    dnsd_cmd('["init","%s","%s",3]\n' % (domain, ip))
                    old_ip = ip
                    init_complete.set()

        except:
            print("Unexpected error while updating dyndns", sys.exc_info()[0])
            print(traceback.format_exc())

        time.sleep(DYNDNS_INTERVAL)

print("\nAppstore starting dyndns thread\n")
dyndns_thread = threading.Thread(target=update_dyndns, daemon=True)
dyndns_thread.start()

#Wait until we have our IP address and have setup dnsd before we serve commands.
init_complete.wait()

#XXX Need to start up all previously installed apps here.

print("\nAppstore serving commands\n")
server = socketserver.TCPServer(('', 9000), AppsTCPHandler)
server.serve_forever()
