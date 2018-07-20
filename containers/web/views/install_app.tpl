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
      document.getElementById("results").innerHTML = (this.status == 200 ?
          "<p style=\"color:green\">Installing: " + this.responseText + "</p>" :
          "<p style=\"color:red\">Couldn't talk to your home server.  Make sure it is online and check ZeroTier setup on your client device.</p> " + this.status + " : " + this.responseText);
      setTimeout(poll, 2000);
      /* XXX Stop polling when install is successful */
    }
  };

  function poll() {
    var appname = "{{appname}}";

    xhr.open("POST", "/install_app", true);
    xhr.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
    xhr.send("app=" + appname);
  }

  window.onload = poll();
</script>

</body>
</html>
