# Jester changelog

## 0.3.0 - 06/07/2018

This is a major new release containing many changes and improvements.
Primary new addition is support for the brand new HttpBeast server which offers
unparalleled performance and scalability across CPU cores.

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


### Other changes

* **Breaking change:** The `body`, `headers`, `status` templates have been
  removed. These may be brought back in the future.
* Templates and macros now work in routes.
* HttpBeast support.
* SameSite support for cookies.
* Multi-core support.

## 0.2.0 - 02/09/2017

## 0.1.1 - 01/10/2016

This release contains small improvements and fixes to support Nim 0.15.0.

* **Breaking change:** The ``ReqMeth`` type was removed in favour of Nim's
  ``HttpMethod`` type.
* The ``CONNECT`` HTTP method is now supported.
