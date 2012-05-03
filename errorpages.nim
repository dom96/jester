import htmlgen
proc error*(err, jesterVer: string): string =
   return html(head(title(err)), 
               body(h1(err), 
                    hr(),
                    p("Jester " & jesterVer),
                    style = "text-align: center;"
               ),
               xmlns="http://www.w3.org/1999/xhtml")