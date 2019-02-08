#!/usr/bin/env python3

from bottle import run, route, request, response, static_file, template
import requests, socket, os

#XXX This needs to escape all user-supplied values that go into JSON/files.

DOMAIN="https://boundery.me"

def enable_cors():
    if request.headers['Origin'] in (DOMAIN, 'http://localhost:8000'):
        response.headers['Access-Control-Allow-Origin'] = request.headers['Origin']
        response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
        response.headers['Vary'] = 'Origin'

@route('/set_apikey', method='POST')
def set_apikey():
    #XXX should check with https://boundery.me and verify the username/apikey pair
    enable_cors()
    response.headers['Content-Type'] = 'application/json; charset=utf8'

    with open('/apikey', 'w') as f:
        f.write(request.forms.apikey)
    with open('/username', 'w') as f:
        f.write(request.forms.user)

    return 'ok'

#XXX This is a terrible hack.  But unfortunately we can't get an TLS cert
#    before we get the API key, and browsers won't AJAX or POST to a http
#    URL from an https page.
@route('/set_apikey.png', method='GET')
def set_apikeypng():
    #XXX should have a token passed in that can be verified against https://boundery.me
    #    since we have to use unsafe GETs here.
    #XXX should check with https://boundery.me and verify the username/apikey pair
    response.headers['Cache-Control'] = 'no-cache, must-revalidate'
    response.headers['Pragma'] = 'no-cache'

    with open('/apikey', 'w') as f:
        f.write(request.query.apikey)
    with open('/username', 'w') as f:
        f.write(request.query.user)

    return static_file('trans1x1.png', root=os.getcwd())

@route('/install_app', method='GET')
def install_app():
    #XXX Setup some kind of magic token that we can verify with https://boundery.me/
    response.headers['Content-Security-Policy'] = 'default-src: *'
    appname = request.query.name
    return template('install_app', appname=appname)

@route('/install_app', method='POST')
def install_app_post():
    #enable_cors()
    response.headers['Content-Type'] = 'application/json; charset=utf8'

    appname = request.forms.app
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('appstore', 9000))
    s.sendall(('{"cmd": "install","args":["%s"]}\n' % appname).encode())
    resp = s.recv(1024).decode()
    s.close()

    return resp

#XXX Switch this to https once we have a cert for it.
#run(host='0.0.0.0', port=443, server='waitress',
#    certfile='server.crt', keyfile='server.key')
run(host='0.0.0.0', port=80, server='waitress')
