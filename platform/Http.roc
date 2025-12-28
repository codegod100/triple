Http := [].{
    get! : Str => {
        requestUrl : Str,
        requestHeaders : Dict(Str, Str),
        responseBody : List(U8),
        responseHeaders : Dict(Str, Str),
        statusCode : U16,
    }
}
