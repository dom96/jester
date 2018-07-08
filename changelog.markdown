# Jester changelog

## 0.3.0 - 06/07/2018

This is a major new release containing many changes and improvements.
Primary new addition is support for the brand new HttpBeast server which offers
unparalleled performance and scalability across CPU cores.

This release also fixes a **security vulnerability**. which even got a
CVE number: CVE-2018-13034. If you are exposing Jester directly to outside users,
i.e. without a reverse proxy (such as nginx), then you are vulnerable and
should upgrade ASAP. See below for details.

### Modular routes

Routes can now be separated into multiple `router` blocks and each block
can be placed inside a separate module. For example:

```nim
import jester

router api:
  get "/names":
    resp "Dom,George,Charles"

  get "/info/@name":
    resp @"name"

routes:
  extend api, "/api"
```

The `api` routes are all prefixed with `/api`, for example
https://localhost:5000/api/names.

### Error handlers

Errors including exceptions and error HTTP codes can now be handled.
For example:

```nim
import jester

routes:
  error Http404:
    resp Http404, "Looks you took a wrong turn somewhere."

  error Exception:
    resp Http500, "Something bad happened: " & exception.msg
```

### Meta routes

Jester now supports `before` and `after` routes. So you can easily perform
actions before or after requests, you don't have to specify a pattern if you
want the handler to run before/after all requests. For example:

```nim
import jester

routes:
  before:
    resp Http200, "<xml></xml>", "text/xml"

  get "/test":
    result[3] = "<content>foobar</content>"
```

### CVE-2018-13034

**The fix for this vulnerability has been backported to Jester v0.2.1.** Use it
if you do not wish to upgrade to Jester v0.3.0 or are stuck with Nim 0.18.0
or earlier.

This vulnerability makes it possible for an attacker to access files outside
your designated `static` directory. This can be done by requesting URLs such as
https://localhost:5000/../webapp.nim. An attacker could potentially access
anything on your filesystem using this method, as long as the running application
had the necessary permissions to read the file.

**Note:** It is recommended to always run Jester applications behind a reverse
proxy such as nginx. If your application is running behind such a proxy then you
are not vulnerable. Services such as cloudflare also protect against this
form of attack.

### Other changes

* **Breaking change:** The `body`, `headers`, `status` templates have been
  removed. These may be brought back in the future.
* Templates and macros now work in routes.
* HttpBeast support.
* SameSite support for cookies.
* Multi-core support.

## 0.2.1 - 08/07/2018

Fixes CVE-2018-13034. See above for details.

## 0.2.0 - 02/09/2017

## 0.1.1 - 01/10/2016

This release contains small improvements and fixes to support Nim 0.15.0.

* **Breaking change:** The ``ReqMeth`` type was removed in favour of Nim's
  ``HttpMethod`` type.
* The ``CONNECT`` HTTP method is now supported.
