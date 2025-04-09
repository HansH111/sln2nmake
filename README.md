# Visual Studio Solution to NMAKE Makefile Converter

`sln2nmake.pl` is a Perl script that converts Visual Studio `.sln` files and their associated `.vcproj` or `.vcxproj` project files into `NMAKE`-compatible `Makefile`s. It generates project-specific `Makefile`s for both `Release` and `Debug` configurations, using backslashes (`\`) for Windows compatibility, and a master `Makefile` to build all projects.

## Features
- Supports legacy `.vcproj` (pre-VS 2010) and modern `.vcxproj` (VS 2010+) files.
- Extracts project details: source files (`.cpp`/`.c`), include directories, linker dependencies, and advanced linker settings (e.g., output file, subsystem, entry point).
- Generates targets for `Win32` and `x64` in both `Release` (`/MT`) and `Debug` (`/MTd`) configurations.
- Creates a master `Makefile` for solution-wide builds.
- Uses backslashes exclusively for Windows `NMAKE` compatibility.

## Usage
```
Syntax : sln2nmake.pl -pl <x64|win32> -conf <debug|release>  
                     [-opts <linker opts>] [-v] <fn.sln> [<vcproj/vcxprojfn>]  
         generate a Makefile from a sln file  
  
Options: -pl      platform, default: x64  
         -conf    config,   default: Release  
         -opts    optional linker options  
         -v       be more verbose  
```
 
## Example
perl sln2nmake.pl MySolution.sln  
or  
perl sln2nmake.pl MySolution.sln MyProject1  
Processes MySolution.sln, generates a Makefile in MyProject1\, and a master Makefile in the current directory.

- Build all projects:
  nmake

- Clean all projects:
  nmake clean

- Build specific configuration:  
    nmake project1   

## Output Structure
    SolutionDir\
    ├── Makefile
    ├── Makefile_Project1
    ├── Makefile_Project2
    ├── Project1\
    │   └── Project1.vcxproj
    ├── Project2\
    │   └── Project2.vcproj
    └── MySolution.sln

## Limitations
- clean target assumes default executable name ($projnm.exe); custom OutputFile paths may not be cleaned.
- Only supports Release and Debug configurations (extendable via code).

## License
MIT License - free to use, modify, and distribute.
