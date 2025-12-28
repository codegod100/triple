Storage := [].{
    save! : Str, Str => Try({}, Str)

    load! : Str => Try(Str, [NotFound, PermissionDenied, Other(Str)])

    delete! : Str => Try({}, Str)

    exists! : Str => Bool

    list! : {} => List(Str)
}
