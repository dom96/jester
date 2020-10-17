# Jester changelog

## 0.5.0 - 17/10/2020

Major new release mainly due to some breaking changes.
This release brings compatibility with Nim 1.4.0 as well.

- **Breaking change:** By default `redirect` now skips future handlers, including when used in a `before` route.  To retain the old behavior, set the parameter `halt=false` (e.g. `redirect("/somewhere", halt=false)`)

For full list, see the commits since the last version:

https://github.com/dom96/jester/compare/v0.4.3...v0.5.0

## 0.4.3 - 12/08/2019

Minor release correcting a few packaging issues and includes some other
fixes by the community.

For full list, see the commits since the last version:

https://github.com/dom96/jester/compare/v0.4.2...v0.4.3

## 0.4.2 - 18/04/2019

This is a minor release containing a number of bug fixes.
**In particular it fixes a 0-day vulnerability**, which allows an attacker to
request static files from outside the static directory in certain circumastances.
See [this commit](https://github.com/dom96/jester/commit/0bf4e344e3d95934780f2e7a39e7eed692b94f09) for a test which reproduces the bug.

For other changes, see the commits since the last version:

https://github.com/dom96/jester/compare/v0.4.1...v0.4.2

## 0.4.1 - 24/08/2018

This is a minor release containing a number of bug fixes. The main purpose of
this release is compatibility with the recent Nim seq/string changes.

## 0.4.0 - 18/07/2018

This is a major new release focusing on optimizations. In one specific benchmark
involving pipelined HTTP requests, the speed up was 650% in comparison to
Jester v0.3.0. For another benchmark using the `wrk` tool, with no pipelining,
the speed up was 178%.

A list of changes follows:

- **Breaking change:** The response headers are now stored in a more efficient
  data structure called ``RawHeaders``. This new data structure is also stored
  in an ``Option`` type, this makes some responses significantly more efficient.
- ``sendFile`` has been implemented, so it's now possible to easily respond
  to a request with a file.

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
http://localhost:5000/api/names.

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
http://localhost:5000/../webapp.nim. An attacker could potentially access
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
