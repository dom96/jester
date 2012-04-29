# Jester

The sinatra-like web framework for Nimrod. Jester provides a DSL for quickly 
creating web applications in Nimrod, it currently mimics sinatra a lot:

```nimrod
# myapp.nim
import jester, strtabs

get "/":
  !"<h1>Hello world</h1>"

run()
```

Compile and run with:

  nimrod c -r myapp.nim


View at: [localhost:5000](http://localhost:5000)