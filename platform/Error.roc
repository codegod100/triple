module [AppError]

AppError : [
    OutOfBounds,
    Exit I32,
    BadUtf8 { index : U64, problem : Str.Utf8Problem },
]
