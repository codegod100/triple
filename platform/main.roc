platform ""
    requires {} { main! : List(Str) => Try({}, [Exit(I32)]) }
    exposes [Stdout, Stderr, Stdin, Random, Http, Logger, Storage]
    packages {}
    provides { main_for_host!: "main_for_host" }
    targets: {
        files: "targets/",
        exe: {
            x64mac: ["libhost.a", app],
            arm64mac: ["libhost.a", app],
            x64musl: ["crt1.o", "libhost.a", app, "libc.a"],
            x64glibc: ["libhost.a", app],
            arm64musl: ["crt1.o", "libhost.a", app, "libc.a"],
            x64win: ["host.lib", app],
            arm64win: ["host.lib", app],
            wasm32: ["libhost.a", app],
        }
    }

import Stdout
import Stderr
import Stdin
import Random
import Http
import Logger
import Storage


main_for_host! : List(Str) => I32
main_for_host! = |args| {
    result = main!(args)
    match result {
        Ok({}) => 0
        Err(Exit(code)) => code
    }
}
