# Debugging

Replique provides an API to capture a local environment (local bindings + dynamic bindings) and to evaluate some code in the context of the captured environment.

## Capturing a local environment

The `replique.interactive/capture-env` macro expands to code that captures the local environment.
The first parameter of `replique.interactive/capture-env` is an atom where the environment must be saved.

A captured environment is a map with the following structure:

```
{;; The captured local bindings
 :locals {a-local-sym "a value"}
 ;; The captured dynamic bindings
 :bindings {clojure.core/*default-data-reader-fn* nil
            clojure.core/*data-readers* {}}
 ;; The position where the environment was captured
 :position "/some/filesystem/path.clj:line:column"
 ;; Other child environment captured (see below)
 :child-envs []}
```

The second argument to `replique.interactive/capture-env` is the body of the macro.
The `replique.interactive/capture-child-env` macro can be used in the body of a `replique.interactive/capture-env` or another `replique.interactive/capture-child-env` macro to append a child environment to the captured environment.
Capturing child environments can be useful for example when debugging recursive functions.

## Using a captured environment

Captured environments can be visualized using the watch feature of Replique (see [Watching / visualizing mutable references](https://github.com/EwenG/replique.el/blob/master/doc/watching-visualizing-mutable-references.md)).

The `replique.interactive/with-env` macro restores the bindings of the captured environment given as first parameter and then executes its body.
The first parameter must be an atom which value is an environment captured by the `replique.interactive/capture-env` macro.
The restored environment is either the value of the atom or, if the atom is beeing watched, its currently browsed value (see [Browsing values](https://github.com/EwenG/replique.el/blob/master/doc/watching-visualizing-mutable-references.md#browsing-values)).
Of course, the browsed value can be a child environment of the top level captured environment.