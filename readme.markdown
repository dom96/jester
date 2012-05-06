# Jester

The sinatra-like web framework for Nimrod. Jester provides a DSL for quickly 
creating web applications in Nimrod, it currently mimics sinatra a lot:

```nimrod
# myapp.nim
import jester, strtabs, htmlgen

get "/":
  resp h1("Hello world")

run()
```

Compile and run with:

  nimrod c -r myapp.nim


View at: [localhost:5000](http://localhost:5000)

## Examples

### Github service hooks

The code for this is pretty similar to the code for Sinatra given here: http://help.github.com/post-receive-hooks/

```nimrod
import jester, json, strtabs

post "/":
  var push = parseJson(@"payload")
  resp "I got some JSON: " & $push

run()
```