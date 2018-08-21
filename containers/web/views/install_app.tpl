<!DOCTYPE html>
<html>
  <head>
    <title>Installing {{appname}}</title>
  </head>
<body>

<h1>Installing {{appname}}</h1>

<div id="results">...</div>

<!-- XXX Need to detect if Javascript is off, and warn appropriately -->
<script type="text/javascript">
    var xhr = new XMLHttpRequest();

    xhr.onreadystatechange = function() {
        if (this.readyState == 4) {
            var poll = true;
            if (this.status == 200) {
                var json = JSON.parse(this.responseText);
                var s = "<p style=\"color:green\">Installing: " + json[1] + "</p>";
                if (json[0] == 100 || json[0] < 0) {
                    poll = false;
                }
               if (json[0] == 100) {
                   window.location.href = "https://boundery.me/apps/installed/{{appname}}/"
               }
            } else {
                var s = "<p style=\"color:red\">Couldn't talk to your home server.  Make sure it is online and check ZeroTier setup on your client device.</p> " + this.status;
            }
            document.getElementById("results").innerHTML = s
            if (poll) {
                setTimeout(poll_install, 1000);
            }
        }
    };

    function poll_install() {
        var appname = "{{appname}}";

        xhr.open("POST", "/install_app", true);
        xhr.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
        xhr.send("app=" + appname);
    }

    window.onload = poll_install();
</script>

</body>
</html>
