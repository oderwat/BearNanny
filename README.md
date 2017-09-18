# BearNanny (experimental)

[Bear](http://www.bear-writer.com/) is my most favorite note-taking application. This experimental shell application extends what you can do by watching the Bear notes and act on their contents.

![Demo 1](assets/demo1.gif)

## Using it:

Start BearNanny either by running `swift run` or build the executable with `swift build -c release -Xswiftc -static-stdlib` and maybe `strip .build/release/BearNanny`.

> I added a (hopefully) working version in the `bin/` folder of the project!
>
>*Please note that this binary won't be updated if you make changes and compile it yourself!*

With that running open up Bear and write a note with the following content:

    # BearNanny Test

    ```swift
    let a = 7
    let b = 8
    print(a * b)<<<
    ```
    ```output
    ```
    ---
    #BearNanny


After a short time BearNanny should output some information to the console (in verbose mode) and the output part of the note should update to:

    ```output 1fquuqd4jqb30
    56
    ```

The characters after the word output are a checksum of the code which helps avoiding recalculation. It also does not update the note if the output is the same as before like when editing comments.

You can have multiple notes and sections which contain such swift code / output sections. BearNanny will check every other second for changes (and runs endlessly).

Using a run trigger (default `<<<`) for re-computing the output has two reasons:

1. Before using the trigger, BearNanny was running the code much to often. Nice for the initial proof of concept but not really useful. Now you can trigger running the code when your changes are done.
2. Bear currently still loses focus and cursor position when a note gets updated from external. So I figured out a very hacky trick to work around this: I figure out the line and column of the trigger in the note. After running the code and updating the note with the new output I create and run a little Apple Script to send keystrokes to the Bear Application which moves the cursor (hopefully) to the location the trigger was found.

You can also define a trigger for code block formatting (currently only for Swift code utilising `swiftformat`) which can be used to re-format a code block with a simple trigger. See below configuration for an example.

#### BearNanny Config

As the code trigger may not fit for your use case you can change it by creating a code block with the following content:

    ```BearNanny
    RunTrigger: <<<
    FormatTrigger: >>>
    FormatOnRun: true
    FormatSwift: swiftformat --indent 2
    ```

*Notice: All occurences of the triggers get erased in the code block when found!*

### Meta blocks

You can now define a meta block which lets you do some more cool stuff:

Here some examples:

#### Saving a code block to the filesystem (and chmod it)

    ```meta
    saveas: ~/bin/myscript
    chmod: 0777
    ```
    ```shell
    #!/bin/bash
    echo "I was created in Bear!
    ```

Saving happens automatically every time the code gets changed. There is no trigger needed!

*Take care as it will not ask you if the file it saves already exists!*

#### Running a shell command on a code block

    ```meta
    run: sort
    ```
    ```
    this
    is
    an
    unsorted
    list
    ```
    ```output 1n1oz33f4bxj0
    an
    is
    list
    this
    unsorted
    ```

#### Running a MySQL Query on a local database

This uses the recently added feature that you can use `<` as last option to a run command which then pipes the code block to the running command as standard input.

    ```meta
    run: mysql -sr -h localhost -u test test <
    ```
    ```sql
    SELECT "SQL Example with some Text!\n\nUserlist:";
    SELECT * FROM users;
    SELECT "";  # creates an empty line
    SELECT CONCAT("Total users: ",COUNT(*)) FROM users;
    SELECT CONCAT("Total age: ",SUM(age)) FROM users;
    ```
    ```output
    SQL Example with some Text!

    Userlist:
    bob	35	2017-09-18 12:51:20
    joe	16	2017-09-18 12:51:29
    max	23	2017-09-18 12:51:43

    Total users: 3
    Total age: 74
    ```

*P.S.: The `-r` option is needed to emit a real linefeed instead of `\n`*

#### PHP (and Python) support

    ```php
    echo date('Y-m-d H:i:s')
    ```
    ```output
    ```

#### Complex Usage

You can combine "run" and "saveas" to store the code you run at the same time. You can even use some "saveas" blocks to transfer data from the note to files which then are used by a "run" code block.

### Synced Content

It will also work on connected devices if you have BearNanny running on one of them :)

## Here some notes about compiling and running it!

### Background and my procedure for creating the package (for reference):

I use XCode 9 beta 6 and [swiftenv](https://swiftenv.fuller.li/en/latest/) (`brew install swiftenv`) for compilation with Swift 4. I just started learning Swift and don't want to force me into learning old stuff which is being outdated soon anyway.

To build this project one needs the Swift 4 version of the SQLite Package. I shortly describe the steps I took to make this work:

Setting up the package was done like this and is already done if you checked out this repository. I list it mostly for reference:

```bash
mkdir BearNanny
cd BearNanny
swiftenv local 4.0 # using Swift 4 here
swift package init --type executable
```

Editing `Package.swift` to contain :

```swift
// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BearNanny",
    dependencies: [
        // Make sure to use the swift-4 branch (by `swift package edit SQLite` and "git co swift-4")
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.11.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "BearNanny",
            dependencies: ["SQLite"]),
    ]
)
```

### What you need to do for successful compilation (needed):

Now marking the SQLite Package as editable and checking out the Swift 4 version and updating the package.

```
swift package edit SQLite
cd Packages/SQLite/
git checkout swift-4
cd -
echo "Package.resolved" >> .gitignore
swift package update
```

### Editing with XCode 9 or AppCode 2017.2 (optional):

Creating the XCode Project (just because I use XCode 9 and AppCode 2017.2 for editing and debugging the files).

```
swift package generate-xcodeproj
```

To be able to compile it with XCode 9 (or AppCode) there needs to be `Enable Modules (C and Objective-C)` set to `Yes` for the target `SQLiteObjc`.

This seems not to matter if compiling with `swift build` or just `swift run` the project.

*I know the SIGINT code is bogus! But it is better than nothing*

### Remember: This is an experimental application to explore the possibilities and one of my very first Swift programming experiences. Have fun!
