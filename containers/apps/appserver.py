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
# docker pull, --max-conc-dl=1:       4m16.807s

# Format: {"cmd": "command", "args": ["arg1", ...]}

DYNDNS_INTERVAL=180

parser = argparse.ArgumentParser(description="Install and run apps")
parser.add_argument("centralurl", help="URL to central")
parser.add_argument("apikey", help="API key for central")
parser.add_argument("domain", help="User's domain name")
args = parser.parse_args()

centralurl = args.centralurl
repo = args.centralurl.split('/')[2]
api_key = args.apikey
domain = args.domain
username = domain.split('.')[0]

assert(centralurl.endswith('/'))

#XXX Build system already knows this, so better to just plumb it in somehow.
if os.uname().machine == 'x86_64':
    arch='amd64'
elif os.uname().machine == 'armv7l':
    arch='arm32v7'
else:
    assert(False)

init_complete = threading.Event()
pub_ip = '0.0.0.0'
inflight = {}

#XXX Need to get a lot more paranoid about validating the .json.
def start_container(appname, name, json):
    d = docker.from_env()
    try:
        cont = d.containers.get(name)
    except docker.errors.NotFound:
        nets = []
        for netname in json.get('networks', []):
            try:
                net = d.networks.get(netname)
            except docker.errors.NotFound:
                net = d.networks.create(netname, driver="bridge")
            nets.append(net)

        args = {'network': 'none', 'detach': True, 'name': name}

        for hostp, guestp in json.get('expose', []):
            args.setdefault('ports', {})[hostp] = guestp

        if 'hostname' in json:
            args['hostname'] = json.get('hostname')

        sds = {'/dev/log': {'bind':'/dev/log', 'mode':'rw'}}
        for guestd in json.get('storagedirs', []):
            hostd = '/mnt/vol00/appdata/%s/%s' % (appname,
                                                  name.strip('/').replace('/', '-'))
            os.makedirs(hostd, mode=0o700, exist_ok=True)
            sds[hostd] = { 'bind': guestd, 'mode': 'rw' }
        if len(sds) > 0:
            args['volumes'] = sds

        env = {'USERNAME': username, 'DOMAINNAME': domain}
        for net in nets:
            env[net.name.replace('-', '_') + "_SUBNET"] = net.attrs['IPAM']['Config'][0]['Subnet']
        args['environment'] = env

        cont = d.containers.create(name, **args)

        #Docker won't let you attach more than 1 container if attached to
        # 'none', so we explicitly disconnect it here.
        d.networks.get('none').disconnect(cont)
        for net in nets:
            net.connect(cont)

    cont.start()
    cont.reload() #So we get the IP address(es).

    #XXX Make sure different apps can't stomp on each other's names!
    for privdns in json.get('PRIVDNS', []):
        #XXX These should be .int. subdomains.
        priv_ip = cont.attrs['NetworkSettings']['Networks']['private']['IPAddress']
        dnsd_cmd('["add","%s","A","%s"]' % (privdns, priv_ip))

    for pubdns in json.get('PUBDNS', []):
        recs = pubdns.split(':')
        if recs[0] == 'MX':
            assert(len(recs) == 3)
            dnsd_cmd('["add","@","MX",["%s.%s.",%s]]' % (recs[1], domain, recs[2]))
        elif recs[0] == 'A':
            assert(len(recs) == 2)
            dnsd_cmd('["add","%s","A","%s"]' % (recs[1], pub_ip))

def start_app(app, json):
    for cname, cj in json['containers'].items():
        print("Starting container %s" % cname)
        start_container(app, app + '-' + cname, cj)

def install_image(app, image, msg):
    full_img = '%s/%s/%s' % (repo, arch, image)
    d = docker.from_env()
    stats = {}

    for line in d.api.pull(full_img, tag='latest', stream=True):
        stat = json.loads(line.decode())
        if 'id' in stat and stat['id'] != 'latest' and 'progress' in stat:
            stats[stat['id']] = stat['progress']
            s = 'Installing app component %s' % msg
            for k, v in stats.items():
                s += '\n<br>%s' % v
            inflight[app] = s

    d.images.get(full_img).tag(image, tag='latest')

def install_app(app):
    try:
        app_cfgfile = app + ".json"

        inflight[app] = "Downloading app description" ; print(inflight[app])
        r = requests.get(centralurl + "static/apps/" + app_cfgfile)
        appj = r.json()
        raw_json = r.content
        r.close()

        inflight[app] = "Installing app" ; print(inflight[app])
        for i, img in enumerate(appj['containers']):
            print("Installing image %s" % app + '-' + img)
            install_image(app, app + '-' + img, "%s of %s" % (i+1, len(appj['containers'])))
        inflight[app] = "Application components installed successfully, starting" ; print(inflight[app])

        start_app(app, appj)
        with open('/appsdir/' + app_cfgfile, "wb") as f:
            f.write(raw_json)
        inflight[app] = "Application started successfully" ; print(inflight[app])
    except:
        #XXX Cleanup .json/images/networks/dnsd/etc.
        #XXX Unset inflight[app] somewhere so user can try again.
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
            app = args[0]
            if os.path.exists("/appsdir/" + app + ".json"):
                self.wfile.write(("App %s is installed." % app).encode())
                if app in inflight:
                    del(inflight[app])
            elif app in inflight:
                self.wfile.write(inflight[app].encode())
            else:
                inflight[app] = 'Starting app install'
                threading.Thread(target=install_app, args=(app,), daemon=True).start()
                self.wfile.write("Starting app install\n".encode())
        else:
            self.wfile.write("unknown command\n".encode())

def dnsd_cmd(cmd):
    print("dnsd_cmd: %s" % cmd)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("dnsd", 54))
    s.sendall((cmd + '\n').encode())
    resp = s.recv(1024)
    s.close()
    return resp.decode()

def update_dyndns():
    global pub_ip
    while True:
        #Ping dyndns every DYNDNS_INTERVAL seconds
        try:
            r = requests.get(centralurl + "api/v1/update_ip/?IP=%s&APIKEY=%s" %
                             (pub_ip, api_key))
            if r.status_code == 200:
                ip = r.text
                r.close()

                if ip != "nop" and ip != pub_ip:
                    print("IP changed: %s -> %s" % (pub_ip, ip))
                    dnsd_cmd('["init","%s","%s",3]' % (domain, ip))
                    pub_ip = ip
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

#Start up all installed apps.
for app in os.scandir('/appsdir'):
    with open(app.path, 'r') as f:
        appj = json.load(f)
    start_app(os.path.splitext(app.name)[0], appj)

print("\nAppstore serving commands\n")
server = socketserver.TCPServer(('', 9000), AppsTCPHandler)
server.allow_reuse_address = True
server.serve_forever()
