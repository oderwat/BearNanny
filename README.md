# BearNanny (experimental)

[Bear](http://www.bear-writer.com/) is my most favorite note-taking application. This experimental shell application extends what you can do by watching the Bear notes and act on their contents.

![Demo 1](assets/demo1.gif)

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

## Using it:

Start BearNanny either by running `swift run` or build the executable with `swift build -c release -Xswiftc -static-stdlib` and maybe `strip .build/release/BearNanny`.

> I added a (hopefully) working version in the `bin/` folder of the project!
>
>*Please note that this binary won't be updated if you make changes and compile it yourself!*

With that running open up Bear and write a note with the following content:

    # BearNanny Test
    Following code will be run by BearNanny and updates the `output` section!
    ```swift
    let a = 7
    let b = 8
    print(a * b)
    ```
    ```output
    ```
    ---
    #BearNanny


After a short time BearNanny should output some information (in verbose mode) and the output part of the note should update to:

    ```output 1mzhegsz6ecmm
    56
    ```

The characters after the word output are a checksum of the code which helps avoiding recalculation. It also does not update the note if the output is the same as before like when editing comments.

You can have multiple notes and sections which contain such swift code / output sections. BearNanny will check every other second for changes (and runs endlessly).

Sadly there is a big problem when updating a note externally and this is that it will lose focus (and also my open the note if not active).

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

#### I added PHP support

    ```php
    echo date('Y-m-d H:i:s')
    ```
    ```output
    ```


It will also work on connected devices if you have BearNanny running on one of them :)

*I know the SIGINT code is bogus! But it is better than nothing*

### Remember: This is an experimental application to explore the possibilities and one of my very first Swift programming experiences. Have fun!