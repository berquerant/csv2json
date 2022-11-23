# csv2json

Convert csv data from stdin into json.

```
$ cat account.csv
id,name,department
1,account1,HR
2,account2,Dev
4,account4,HR
3,account3,PR
$ json2csv -i < account.csv
{"id":1,"name":"account1","department":"HR"}
{"id":2,"name":"account2","department":"Dev"}
{"id":4,"name":"account4","department":"HR"}
{"id":3,"name":"account3","department":"PR"}
$ json2csv < account.csv
["id","name","department"]
[1,"account1","HR"]
[2,"account2","Dev"]
[4,"account4","HR"]
[3,"account3","PR"]
```

## Package management

Depends on:

- [build.zig](./build.zig)
- [requirements.txt](./requirements.txt)
- [package.sh](./package.sh)

The format of a row of requirements.txt is:

```
LOCATION VERSION ENTRANCE
```

`LOCATION` is a part of the repo url with schema stripped.  
`VERSION` is a tag or a commit hash.
`ENTRANCE` is a target zig file to `@import`, relative to the root of the repo.

## Requirements

- zig 0.10.0 or later
