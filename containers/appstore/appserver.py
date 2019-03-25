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

USERINFO_POLL_INTERVAL=5
DYNDNS_INTERVAL=180

parser = argparse.ArgumentParser(description="Install and run apps")
parser.add_argument("centralurl", help="URL to central")
parser.add_argument("apikey", help="API key for central")
parser.add_argument("root_domain", help="Root domain name for user subdomains")
args = parser.parse_args()

centralurl = args.centralurl
repo = args.centralurl.split('/')[2]
apikey = args.apikey
root_domain = args.root_domain

print("Getting userinfo", end='')
username = None
try:
    with open('/data/username', 'r') as f:
        username = f.read().strip()
if username is None:
    while True:
        print(".", end='')
        try:
            req = requests.get(centralurl + '/api/v1/get_userinfo/',
                                   params = { "APIKEY": apikey })
            if req.status_code == 200:
                username = req.json()['username']
                with open('/data/username', 'w') as f:
                    f.write(username)
                break
            except requests.exceptions.RequestException as e:
                pass
            except:
                print("Unexpected exception!")
                pass
            time.sleep(USERINFO_POLL_INTERVAL)
print("success: %s" % username)
domain = username + '.' + root_domain

if os.uname().machine == 'x86_64':
    arch='amd64'
elif os.uname().machine == 'armv7l':
    arch='arm32v7'
else:
    assert(False)

init_complete = threading.Event()
pub_ip = '0.0.0.0'
inflight = {}

def progress(app, msg, state, log = True):
    inflight[app] = [state, msg]
    if log:
        print(inflight[app])

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
            #XXX hostd must incorporate guestd for >1 storagedirs, a hash?
            hostd = '/mnt/vol00/appdata/%s/%s' % (appname,
                                                  name.strip('/').replace('/', '-'))
            os.makedirs(hostd, mode=0o700, exist_ok=True)
            sds[hostd] = { 'bind': guestd, 'mode': 'rw' }
        if len(sds) > 0:
            args['volumes'] = sds

        env = {'USERNAME': username, 'DOMAINNAME': domain}
        for pair in json.get('env', []):
            var, val = pair.split('=')
            env[var] = val
        for net in nets:
            env[net.name.replace('-', '_') + "_SUBNET"] = net.attrs['IPAM']['Config'][0]['Subnet']
        args['environment'] = env

        image_name = json.get('reuse', name)
        cont = d.containers.create(image_name, **args)

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
            progress(app, s, 1, log=False)

    d.images.get(full_img).tag(image, tag='latest')

def install_app(app):
    try:
        app_cfgfile = app + ".json"

        progress(app, "Downloading app description", 1)
        r = requests.get(centralurl + "/static/apps/" + app_cfgfile)
        appj = r.json()
        raw_json = r.content
        r.close()

        progress(app, "Installing app", 1)
        for i, img in enumerate(appj['containers']):
            if 'reuse' in appj['containers'][img]:
                print("Skipping %s-%s due to 'reuse'" % (app, img))
                continue
            print("Installing image %s" % app + '-' + img)
            install_image(app, app + '-' + img, "%s of %s" % (i+1, len(appj['containers'])))
        progress(app, "Application components installed successfully, starting", 1)

        start_app(app, appj)
        with open('/appsdir/' + app_cfgfile, "wb") as f:
            f.write(raw_json)
        progress(app, "Application started successfully", 100)
    except:
        #XXX Cleanup .json/images/networks/dnsd/etc.
        print("Exception: %s %s %s" % sys.exc_info())
        print(traceback.format_exc())
        progress(app,  "ERROR %s %s" % (html.escape(str(sys.exc_info()[0])),
                                         html.escape(str(sys.exc_info()[1]))), -1)

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
                self.wfile.write('[100,"App is installed"]\n'.encode())
                if app in inflight:
                    del(inflight[app]) #General cleanliness.
            elif app in inflight:
                self.wfile.write(json.dumps(inflight[app]).encode())
                if inflight[app][0] < 0:
                    del(inflight[app]) #Cleanup after failure so user can try again.
            else:
                progress(app, 'Starting app install', 1)
                threading.Thread(target=install_app, args=(app,), daemon=True).start()
                self.wfile.write(json.dumps(inflight[app]).encode())
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
            r = requests.get(centralurl + "/api/v1/update_ip/?IP=%s&APIKEY=%s" %
                             (pub_ip, apikey))
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
    try:
        with open(app.path, 'r') as f:
            appj = json.load(f)
        start_app(os.path.splitext(app.name)[0], appj)
    except Exception as e:
        print("Error starting %s" % app)
        print(traceback.format_exc())

print("\nAppstore serving commands\n")
server = socketserver.TCPServer(('', 9000), AppsTCPHandler)
server.allow_reuse_address = True
server.serve_forever()
