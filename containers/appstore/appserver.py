import socketserver
import sys, os, argparse, json, time, docker, requests, socket
import threading, html, traceback, subprocess

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
except:
    username = None
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
elif os.uname().machine == 'aarch64':
    arch='arm64v8'
else:
    assert(False)

init_complete = threading.Event()
pub_ip = '0.0.0.0'
inflight = {}

def progress(app, msg, state, log = True):
    inflight[app] = [state, msg]
    if log:
        print(inflight[app])

#XXX Need a thread to try call periodically to renew.
#XXX Need to handle being rate limited here somehow.
def get_cert(domain, keydir):
    fullchain_path = os.path.join(keydir, 'fullchain.pem')
    renew = os.path.exists(fullchain_path)
    if renew and subprocess.run(['openssl', 'x509', '-checkend', str(30 * 86400),
                           '-noout', '-in', fullchain_path]).returncode == 0:
        return

    print('getting cert for %s' % domain)
    d = docker.from_env()
    out = d.containers.run(command=[ 'certmgr',
                                         '--fullchain', '/keys/fullchain.pem',
                                         '--privkey', '/keys/privkey.pem',
                                         '--daemon',
                                         "renew" if renew else "new", domain, ],
                                image='certmgr', network='dnsdcontrol',
                                stdout=True, stderr=True, auto_remove=True,
                                volumes={ keydir: { 'bind':'/keys', 'mode':'rw' }, })
    if json.loads(out.decode('us-ascii'))[0] != 0:
        raise Exception("Couldn't create certificate: %s" % out)

#XXX Need to get a lot more paranoid about validating the .json.
#XXX Let json.dumps generate json, instead of building it as strings.
def start_container(appname, name, json):
    d = docker.from_env()

    if 'TLSCert' in json:
        tlscert = json['TLSCert']
        keydir = "/mnt/vol00/appcerts/%s/keys-%s" % (appname, name)
        get_cert("%s.%s" % (json['hostname'], domain), keydir)

    try:
        #XXX Need to do something so that apps can't steal each other's containers.
        cont = d.containers.get(name)
    except docker.errors.NotFound:
        nets = []
        #XXX Need to do something so that apps can't steal each other's private networks.
        for netname in json.get('networks', []):
            try:
                net = d.networks.get(netname)
            except docker.errors.NotFound:
                net = d.networks.create(netname, driver="bridge")
            nets.append(net)

        args = {'network': 'none', 'detach': True, 'name': name}

        for hostp, guestp in json.get('expose', []):
            args.setdefault('ports', {})[hostp] = guestp

        args['hostname'] = json.get('hostname')

        #XXX Watch out for ".." and friends in the appname/name/guestd name.
        sds = {'/dev/log': {'bind':'/dev/log', 'mode':'rw'}}
        if 'TLSCert' in json:
            sds[keydir] = { 'bind':tlscert['keydir'], 'mode':'ro' }
        for guestd in json.get('storagedirs', []):
            hostd = '/mnt/vol00/appdata/%s/%s-%s' % (appname, name,
                                                         guestd.strip('/').replace('/', '-'))
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

        if 'reuse' in json:
            #XXX Validate that reuse is one of the other images in this app.
            image_name = "%s-%s" % (appname, json['reuse'])
        else:
            image_name = name

        cont = d.containers.create(image_name, **args)

        #Docker won't let you attach more than 1 container if attached to
        # 'none', so we explicitly disconnect it here.
        d.networks.get('none').disconnect(cont)
        for net in nets:
            net.connect(cont)

    cont.start()
    cont.reload() #So we get the IP address(es).

    #XXX Make sure different apps can't stomp on each other's names!
    #XXX 'hostname' vs 'PRIVDNS'/'PUBDNS' is weird, unify?
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
    #XXX Thread this.
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
        with open('/mnt/vol00/apps/' + app_cfgfile, "wb") as f:
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
            if os.path.exists("/mnt/vol00/apps/" + app + ".json"):
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
for app in os.scandir('/mnt/vol00/apps'):
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
