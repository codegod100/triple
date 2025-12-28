Storage := [].{
    save! : Str, Str => Result({}, Str)

    load! : Str => Result(Str, [NotFound, PermissionDenied, Other(Str)])

    delete! : Str => Result({}, Str)

    exists! : Str => Bool

    list! : {} => List(Str)
}
