// avio_list_dir — list a directory via AVIO (local or remote).
//
// Build / run:
//   odin run vendor/ffmpeg/examples/avio_list_dir/ -- /path/to/dir
package main

import avfmt "../avformat"
import "core:fmt"
import "core:os"
import "core:strings"

type_name :: proc(t: avfmt.IODirEntryType) -> string {
    #partial switch t {
    case .Directory:
        return "dir"
    case .File:
        return "file"
    case .SymbolicLink:
        return "link"
    case .BlockDevice:
        return "block"
    case .CharacterDevice:
        return "char"
    case .NamedPipe:
        return "fifo"
    case .Socket:
        return "socket"
    case:
        return "unknown"
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: avio_list_dir <url>")
        os.exit(1)
    }

    url := strings.clone_to_cstring(os.args[1])
    defer delete(url)

    ctx: ^avfmt.IODirContext
    if avfmt.open_dir(&ctx, url, nil) < 0 {
        fmt.eprintfln("error: cannot open directory '%s'", os.args[1])
        os.exit(1)
    }
    defer avfmt.close_dir(&ctx)

    for {
        entry: ^avfmt.IODirEntry
        ret := avfmt.read_dir(ctx, &entry)
        if ret < 0 {
            fmt.eprintln("error: read_dir failed")
            break
        }
        if entry == nil { break }

        fmt.printf("%-10s %12d  %s\n", type_name(avfmt.IODirEntryType(entry.type)), entry.size, entry.name)

        avfmt.free_directory_entry(&entry)
    }
}
