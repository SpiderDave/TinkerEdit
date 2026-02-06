import times

const
    buildUtcIso = CompileDate & "T" & CompileTime & "Z"

proc computeVersion(): string =
    let utcDt = parse(
        buildUtcIso,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        utc()
    )
    let localBuild = utcDt.inZone(local())
    "v" & localBuild.format("yyyy.MM.dd")

type
    App* = object
        name*: string
        version*: string
        author*: string
        url*: string
        date*: string
        time*: string
        description*: string
        stage*: string
        nimVersion*: string

proc newApp*(
    name, author, url, description: string,
    stage = "Prerelease"
): App =
    result.name = name
    result.version = computeVersion()
    result.author = author
    result.url = url
    result.date = CompileDate
    result.time = CompileTime
    result.description = description
    result.stage = stage
    result.nimVersion = NimVersion

proc info*(app: App): string =
    return app.name & " " & app.version & "-" & app.stage & " by " & app.author & " (" & app.url & ")"

proc releaseTag*(app: App): string =
    return app.name & " " & app.version & "-" & app.stage
