import socketserver
import sys, os, io, argparse, json, time, docker, requests, socket, threading, lzma, html

#netcat_over_wifi | xz -d >/dev/null: 0m42.195s
#+untar_no_write_to_fs:               0m43.906s
#+untar_to_sda1:                      0m54.738s
#+untar_to_vol00:                     1m15.985s
#
#uncompressed_nc_over_wifi | tar -t:  0m48.975s
#
#docker load of .xz:                  3m53.158s
#docker load of .tar:                 4m34.725s
#
#appc, unxz in apps, docker.py (BUF_SIZE=4096):
#appc:                                17m10s
#python3 active:                      16m19s
#dockerd active (25-75% wait):        18m40s

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

BUF_SIZE=4096

inflight = {}

def iter_to_stream(iterable, buffer_size=io.DEFAULT_BUFFER_SIZE):
    """
    Lets you use an iterable (e.g. a generator) that yields bytestrings as a read-only
    input stream.
    """
    class IterStream(io.RawIOBase):
        def __init__(self):
            self.leftover = None
        def readable(self):
            return True
        def readinto(self, b):
            try:
                l = len(b)  # We're supposed to return at most this much
                chunk = self.leftover or next(iterable)
                output, self.leftover = chunk[:l], chunk[l:]
                b[:len(output)] = output
                return len(output)
            except StopIteration:
                return 0    # indicate EOF
    return io.BufferedReader(IterStream(), buffer_size=buffer_size)

def install_app(app):
    try:
        dclient = docker.from_env()

        inflight[app] = "Downloading app" ; print(inflight[app])
        with open('/appscripts/' + app + ".tar.xz.part", "wb") as f:
            r = requests.get(centralurl + "static/apps/" + app + ".tar.xz", stream=True)
            for chunk in r.iter_content(chunk_size=4096):
                if chunk:
                    f.write(chunk)
            os.rename('/appscripts/' + app + ".tar.xz.part",
                      '/appscripts/' + app + ".tar.xz")
            r.close()
        #r = requests.get(centralurl + "static/apps/" + app + ".tar.xz", stream=True)
        #fo = iter_to_stream(r.iter_content(chunk_size = BUF_SIZE),
        #                        buffer_size = BUF_SIZE)
        #dclient.load_image(lzma.open(fo, 'rb'))
        #r.close()
        #with open('/appscripts/' + app + ".tar.xz", "wb") as f:
        #    f.write('') #XXX Even worse HACK!

        inflight[app] = "Installing app" ; print(inflight[app])
        r = requests.get(centralurl + "static/apps/start" + app)
        with open('/appscripts/start' + app, 'wb') as f:
            f.write(r.content)
        r.close()
        #XXX Someone needs to start the app.
        inflight[app] = "Application installed successfully"  ; print(inflight[app])
    except:
        print("Exception: %s %s %s" % sys.exc_info())
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
