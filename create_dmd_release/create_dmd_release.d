/+++
Prerequisites to Compile:
-------------------------
- Working D compiler

Prerequisites to Run:
---------------------
- A 64-bit multi-lib OS
- Git
- Posix: zip (Info-ZIP) and 7z (p7zip) (On Windows, these will automatically
  be downloaded if necessary.)
- Posix: Working gcc toolchain, including GNU make which is not installed on
  FreeBSD by default.
- Windows: Working DMC and MSVC toolchains. The default make must be DM make.
  Also, these environment variables must be set:
    VCDIR:  Visual C directory
    SDKDIR: Windows SDK directory
  Examples:
    set VCDIR=C:\Program Files (x86)\Microsoft Visual Studio 8\VC\
    set SDKDIR=C:\Program Files\Microsoft SDKs\Windows\v7.1\
- Windows: A version of OPTLINK with the /LA[RGEADDRESSAWARE] flag:
    <https://github.com/DigitalMars/optlink/commit/475bc5c1fa28eaf899ba4ac1dcfe2ab415db16c6>
- Windows: Microsoft's HTML Help Workshop on the PATH.

Typical Usage:
--------------
0. Obtain/install all prerequisites above.

1. (An unfortunately necessary step:) Download this file:
<http://semitwist.com/download/app/dmd-localextras.7z>
This contains the handful of files not under version control which are needed
by DMD. These are in directories named 'localextras-[os]' which match the
directory structure of DMD. Extract that file, and if necessary, update any
of the files to the latest versions, or add any new files as desired.

2. On 64-bit multilib versions of each supported OS (Windows, OSX, Linux, and
FreeBSD), genrate the platform-specific releases by running this (from
whatever directory you want the resulting archives placed):

$ [path-to]/create_dmd_release v2.064 --extras=[path-to]/localextras-[os] --archive-zip --archive-7z

Optionally substitute "v2.064" with either "master" or the git tag name of the
desired release (must be at least "v2.064"). For beta releases, you can use a
branch name like "2.064". View all options with "create_dmd_release --help".

3. Copy the resulting .zip and .7z files to a single directory on any
non-Windows machine (Windows would mess up the symlinks), and generate the
combined-OS release like this:

$ [path-to]/create_dmd_release v2.064 --combine-zip --combine-7z

4. Distribute all the .zip and .7z files.

Extra notes:
------------
This tool keeps a deliberately strong separation between each of the main stages:

1. Clone   (from GitHub, into a temp dir)
2. Build   (compile everything, including docs, within the temp dir)
3. Package (generate an OS-specific release as a directory)
4. Archive (zip the OS-specific packaged release directory)
5. Combine (create the all-OS release archive from multiple OS-specific ones)

Aside from helping to ensure correctness, this separation means the process
can be resumed or restarted beginning at any of the above steps (see
the --skip-* flags in the --help screen).

The last two steps, archive and combine, are not performed by default. To
perform the archive step, supply any (or all) of the --archive-* flags.
You can create an archive without repeating the earlier clone/build/package
steps by including the --skip-package flag.

The final step, combine, is completely separate. You must first run this tool
on each of the target OSes to create the OS-specific archives. Then copy all
the archives to a single directory on any Posix system (not Windows because
that would destroy the symlinks in the posix archives). Then, from that
directory, run this tool with any/all of the --combine-* flags.

Internal Note: Anything that's independent of 32/64-bits, or is combined
32/64-bits (such as documentation) is treated as if it were 32-bit-only.
+/

import std.algorithm;
import std.array;
import std.file;
import std.getopt;
import std.exception;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.string;

immutable defaultWorkDirName = ".create_dmd_release";
immutable unzipBannerRegex = `^UnZip [^\n]+by Info-ZIP`;
immutable zipBannerRegex   = `^Copyright [^\n]+Info-ZIP`;

immutable osDirNameWindows = "windows";
immutable osDirNameFreeBSD = "freebsd";
immutable osDirNameLinux   = "linux";
immutable osDirNameOSX     = "osx";

immutable allOsDirNames = [
    osDirNameFreeBSD, osDirNameOSX, osDirNameWindows, osDirNameLinux
];

version(Windows)
{
    immutable makefile      = "win32.mak";
    immutable makefile64    = "win64.mak";
    immutable devNull       = "NUL";
    immutable exe           = ".exe";
    immutable lib           = ".lib";
    immutable obj           = ".obj";
    immutable dll           = ".dll";
    immutable generatedDocs = "dlang.org";
    immutable libPhobos32   = "phobos";
    immutable libPhobos64   = "phobos64";
    immutable tool7z        = "7za";

    immutable osDirName     = osDirNameWindows;
    immutable make          = "make";
    immutable useBitsSuffix = false; // Ie: "bin"/"lib" or "bin32"/"lib32"

    immutable libCurlVersion = "7.32.0"; // Windows-only

    // Additional Windows-only stuff for auto-downloading zip/7z tools
    immutable unzipUrl  = "http://semitwist.com/download/app/unz600xn.exe";
    immutable zipUrl    = "http://semitwist.com/download/app/zip232xn.zip";
    immutable tool7zUrl = "http://semitwist.com/download/app/7za920.zip";

    immutable unzipArchiveName  = "unzip-sfx.exe";
    immutable zipArchiveName    = "zip.zip";
    immutable tool7zArchiveName = "7z.zip";

    immutable dloadToolFilename = "download.vbs";
    immutable dloadToolContent =
`Option Explicit
Dim args, http, fileSystem, adoStream, url, target, status

Set args = Wscript.Arguments
Set http = CreateObject("WinHttp.WinHttpRequest.5.1")
url = args(0)
target = args(1)

http.Open "GET", url, False
http.Send
status = http.Status

If status <> 200 Then
    WScript.Echo "FAILED to download: HTTP Status " & status
    WScript.Quit 1
End If

Set adoStream = CreateObject("ADODB.Stream")
adoStream.Open
adoStream.Type = 1
adoStream.Write http.ResponseBody
adoStream.Position = 0

Set fileSystem = CreateObject("Scripting.FileSystemObject")
If fileSystem.FileExists(target) Then fileSystem.DeleteFile target
adoStream.SaveToFile target
adoStream.Close
`;
}
else version(Posix)
{
    immutable makefile      = "posix.mak";
    immutable makefile64    = "posix.mak";
    immutable devNull       = "/dev/null";
    immutable exe           = "";
    immutable lib           = ".a";
    immutable obj           = ".o";
    immutable dll           = ".so";
    immutable generatedDocs = "dlang.org/web";
    immutable libPhobos32   = "libphobos2";
    immutable libPhobos64   = "libphobos2";
    immutable tool7z        = "7z";

    version(FreeBSD)
        immutable osDirName = osDirNameFreeBSD;
    else version(linux)
        immutable osDirName = osDirNameLinux;
    else version(OSX)
        immutable osDirName = osDirNameOSX;
    else
        static assert(false, "Unsupported system");
    
    version(FreeBSD)
        immutable make = "gmake";
    else
        immutable make = "make";

    version(OSX)
        immutable useBitsSuffix = false;
    else
        immutable useBitsSuffix = true;
}
else
    static assert(false, "Unsupported system");

/// Fatal error message to exit cleanly with.
class Fail : Exception
{
    this(string msg) { super(msg); }
}

/// Minor convenience func
void fail(string msg)
{
    throw new Fail(msg);
}

enum Bits { bits32, bits64 }
string toString(Bits bits)
{
    return bits == Bits.bits32? "32-bit" : "64-bit";
}

void showHelp()
{
    writeln((`
        Create DMD Release - Build: ` ~ __TIMESTAMP__ ~ `
        Usage:   create_dmd_release --extras=path [options] TAG_OR_BRANCH [options]
        Example: create_dmd_release --extras=`~osDirName~`-extra --archive-zip v2.064

        Generates a platform-specific DMD release as a directory tree.
        Optionally, it can also generate archived releases.
        This must be run on a 64-bit multilib OS.
        
        TAG_OR_BRANCH:     GitHub tag/branch of DMD to generate a release for.
        
        Your temp dir is:
        ` ~ defaultWorkDir ~ `
        
        Options:
        --help             Display this message and exit.
        -q,--quiet         Quiet mode.
        -v,--verbose       Verbose mode.

        --extras=path      Include additional files from 'path'. The path should be a
                           directory tree matching the DMD release structure (including
                           the 'dmd2' dir). All files in 'path' will be included in
                           the release. This is required, in order to include all
                           the DM bins/libs that are not on GitHub.

        --skip-clone       Instead of cloning DMD repos from GitHub, use
                           alreay-existing clones. Useful if you've already run
                           create_release and don't want to repeat the cloning process.
                           The repositories will NOT be switched to TAG_OR_BRANCH,
                           TAG_OR_BRANCH will ONLY be used for directory/archive names.
                           Default path is the temp dir (see above).

        --use-clone=path   Instead of cloning DMD repos from GitHub, use the existing
                           clones in the given path. Implies --skip-clone.
                           Use with caution! There's no guarantee the result will
                           be consistent with GitHub!

        --skip-build       Don't build DMD, assume all tools/libs are already built.
                           Implies --skip-clone. Can be used with --use-clone=path.
        
        --skip-package     Don't create release directory, assume it has already been
                           created. Useful together with --archive-* options.
                           Implies --skip-build.

        --archive-zip      Create platform-specific zip archive.
        --archive-7z       Create platform-specific 7z archive.
        
        --combine-zip      (Posix-only) Combine all platform-specific archives in
                           current directory into cross-platform zip archive.
                           Cannot be used on Windows because the symlinks would be
                           destroyed. Implies --skip-package.

        --combine-7z       (Posix-only) Just like --combine-zip, but makes a 7z.
        
        --clean            Delete temporary dir (see above) and exit.
        `).outdent().strip()
    );
}

bool quiet;
bool verbose;
bool skipClone;
bool skipBuild;
bool skipPackage;
bool shouldZip;
bool should7z;
bool shouldArchive;
bool combineZip;
bool combine7z;
bool combineArchive;
bool needZip; // Was a flag given that requires using zip?
bool need7z;  // Was a flag given that requires using 7z?

version(Windows)
{
    bool hasUnzip; // Is unzip (Info-ZIP) already installed on this system?
    bool hasZip;   // Is zip (Info-ZIP) already installed on this system?
    bool has7z;    // Is 7z already installed on this system?
    string dloadToolPath;
    string unzipArchiveDir;
    string zipArchiveDir;
    string tool7zArchiveDir;
}

// These are absolute and do NOT contain a trailing slash:
string defaultWorkDir;
string cloneDir;
string origDir;
string releaseDir;
string releaseBin32Dir;
string releaseLib32Dir;
string releaseBin64Dir;
string releaseLib64Dir;
string osDir;
string allExtrasDir;
string osExtrasDir;
string customExtrasDir;
string win64vcDir;
string win64sdkDir;

int main(string[] args)
{
    defaultWorkDir = buildPath(tempDir(), defaultWorkDirName);

    bool help;
    bool clean;
    
    try
    {
        getopt(
            args,
            std.getopt.config.caseSensitive,
            "help",         &help,
            "q|quiet",      &quiet,
            "v|verbose",    &verbose,
            "skip-clone",   &skipClone,
            "use-clone",    &cloneDir,
            "skip-build",   &skipBuild,
            "skip-package", &skipPackage,
            "clean",        &clean,
            "extras",       &customExtrasDir,
            "archive-zip",  &shouldZip,
            "archive-7z",   &should7z,
            "combine-zip",  &combineZip,
            "combine-7z",   &combine7z,
        );
    }
    catch(Exception e)
    {
        if(isUnrecognizedOptionException(e))
        {
            errorMsg(e.msg ~ "\nRun with --help to see options.");
            return 1;
        }
        
        throw e;
    }
    
    // Handle command line args
    if(help)
    {
        showHelp();
        return 0;
    }
    
    if(args.length != 2 && !clean)
    {
        errorMsg("Missing TAG_OR_BRANCH.\nSee --help for more info.");
        return 1;
    }
    
    if(quiet && verbose)
    {
        errorMsg("Can't use both --quiet and --verbose");
        return 1;
    }
    
    shouldArchive  = shouldZip  || should7z;
    combineArchive = combineZip || combine7z;

    needZip = shouldZip || combineZip;
    need7z  = should7z  || combineArchive;

    version(Windows)
    {
        if(combineArchive)
        {
            errorMsg("--combine-* flags cannot be used on Windows because the symlinks would be destroyed.");
            return 1;
        }
    }
    
    if(combineArchive)
        skipPackage = true;
    
    if(skipPackage)
        skipBuild = true;
    
    if(cloneDir != "" || skipBuild)
        skipClone = true;
    
    if(skipPackage && !shouldArchive && !combineArchive)
    {
        errorMsg("Nothing to do! Specified --skip-package, but no --archive-* or --combine-* flags");
        return 1;
    }
    
    if(customExtrasDir == "" && !combineArchive)
    {
        errorMsg("--extras=path is required.\nSee --help for more info.");
        return 1;
    }
    else
        customExtrasDir = customExtrasDir.absolutePath().chomp("\\").chomp("/");
    
    // Do the work
    try
    {
        if(clean)
        {
            removeDir(defaultWorkDir);
            return 0;
        }

        if(customExtrasDir != "")
            ensureDir(customExtrasDir);

        string branch = args[1];
        init(branch);
        initTools();

        if(!skipClone)
            cloneSources(branch);

        // No need for the cloned repos if we're not generating
        // the release directory.
        if(!skipPackage)
            ensureSources();
        
        // No need to clean if we just cloned, or if we're not building.
        if(skipClone && !skipBuild) 
            cleanAll();
        
        if(!skipBuild)
            buildAll();
        
        if(!skipPackage)
            createRelease(branch);

        if(shouldZip)
            createZip(branch);
        
        if(should7z)
            create7z(branch);
        
        if(combineZip || combine7z)
            extractOsArchives(branch);
        
        if(combineZip)
            createCombinedZip(branch);
        
        if(combine7z)
            createCombined7z(branch);
        
        infoMsg("Done!");
    }
    catch(Fail e)
    {
        // Just show the message, omit the stack trace.
        errorMsg(e.msg);
        return 1;
    }
    
    return 0;
}

void init(string branch)
{
    // Setup directory paths
    origDir = getcwd();
    releaseDir = origDir ~ `/dmd.` ~ branch ~ "." ~ osDirName;
    if(cloneDir == "")
        cloneDir = defaultWorkDir;

    auto suffix32 = useBitsSuffix? "32" : "";
    auto suffix64 = useBitsSuffix? "64" : "";
    osDir = releaseDir ~ "/dmd2/" ~ osDirName;
    releaseBin32Dir = osDir ~ "/bin" ~ suffix32;
    releaseLib32Dir = osDir ~ "/lib" ~ suffix32;
    releaseBin64Dir = osDir ~ "/bin" ~ suffix64;
    releaseLib64Dir = osDir ~ "/lib" ~ suffix64;
    allExtrasDir = cloneDir ~ "/installer/create_dmd_release/extras/all";
    osExtrasDir  = cloneDir ~ "/installer/create_dmd_release/extras/" ~ osDirName;

    version(Windows)
    {
        unzipArchiveDir  = cloneDir~"/unzip";
        zipArchiveDir    = cloneDir~"/zip";
        tool7zArchiveDir = cloneDir~"/7z";
    }

    // Check for required external tools
    if(!skipClone)
        ensureTool("git");
    
    // Check for archival tools
    version(Posix)
    {
        if(needZip)
            ensureTool("zip", "-v", zipBannerRegex);
        
        if(need7z)
            ensureTool(tool7z);
    }
    else version(Windows)
    {
        hasUnzip = true;
        hasZip = true;
        has7z = true;

        if(!checkTool("unzip", "--help", unzipBannerRegex))
            hasUnzip = false;
        
        if(!checkTool("zip", "-v", zipBannerRegex))
            hasZip = false;
        
        if(!checkTool(tool7z))
            has7z = false;
    }
    else
        static assert(false, "Unsupported platform");
    
    // Check for DMC and MSVC toolchains
    version(Windows)
    {
        // Small workaround because DMC/MAKE's help screens don't return exit code 0
        enum dummyFile  = ".create_release_dummy";
        std.file.write(dummyFile, "");
        scope(exit) removeFile(dummyFile);

        ensureTool("dmc", "-c "~dummyFile);
        ensureTool(make, "-f "~dummyFile);

        // Check DMC's OPTLINK (not just any OPTLINK on the PATH)
        enum dummyCFile = ".create_release_dummy.c";
        std.file.write(dummyCFile, "void main(){}");
        scope(exit) removeFile(dummyCFile);

        enum dummyOptlinkHelp = ".create_release_optlink_help";
        run("dmc "~dummyCFile~" -L/? > "~dummyOptlinkHelp);
        scope(exit) removeFile(dummyOptlinkHelp);
        
        if(!checkTool("type", dummyOptlinkHelp, `OPTLINK \(R\) for Win32`))
            fail("DMC appears to be missing OPTLINK");

        if(!checkTool("type", dummyOptlinkHelp, `OPTLINK \(R\) for Win32.*LA\[RGEADDRESSAWARE\]`))
        {
            fail("Your DMC's OPTLINK does not support /LARGEADDRESSAWARE. You must "~
                "use a newer OPTLINK. See <http://wiki.dlang.org/Building_OPTLINK>");
        }
        
        // Check MSVC tools needed for 64-bit
        if(environment.get("VCDIR", "") == "" || environment.get("SDKDIR", "") == "")
        {
            fail(`
                Environment variables VCDIR and SDKDIR must both be set. For example:
                set VCDIR=C:\Program Files (x86)\Microsoft Visual Studio 8\VC\
                set SDKDIR=C:\Program Files\Microsoft SDKs\Windows\v7.1\
            `.outdent().strip());
        }
        
        win64vcDir  = environment[ "VCDIR"].chomp("\\").chomp("/");
        win64sdkDir = environment["SDKDIR"].chomp("\\").chomp("/");

        verboseMsg("VCDIR:  " ~ displayPath(win64vcDir));
        verboseMsg("SDKDIR: " ~ displayPath(win64sdkDir));
        
        ensureTool(quote(win64vcDir~"/bin/amd64/cl.exe"), "/?");
        try
        {
            ensureDir(win64sdkDir);
            ensureDir(win64sdkDir~"/Bin");
            ensureDir(win64sdkDir~"/Include");
            ensureDir(win64sdkDir~"/Lib");
            ensureDir(win64sdkDir~"/License");
            ensureDir(win64sdkDir~"/Redist");
            ensureDir(win64sdkDir~"/Samples");
            ensureDir(win64sdkDir~"/Setup");
        }
        catch(Fail e)
            fail("SDKDIR doesn't appear to be a proper Windows SDK: " ~ environment["SDKDIR"]);
    }
    else
        // Check for GNU make
        ensureTool(make);
}

void cloneSources(string branch)
{
    ensureNotFile(cloneDir);
    removeDir(cloneDir);
    makeDir(cloneDir);
    changeDir(cloneDir);
    
    gitClone("https://github.com/D-Programming-Language/dmd.git",       "dmd",       branch);
    gitClone("https://github.com/D-Programming-Language/druntime.git",  "druntime",  branch);
    gitClone("https://github.com/D-Programming-Language/phobos.git",    "phobos",    branch);
    gitClone("https://github.com/D-Programming-Language/tools.git",     "tools",     branch);
    gitClone("https://github.com/D-Programming-Language/dlang.org.git", "dlang.org", branch);
    gitClone("https://github.com/D-Programming-Language/installer.git", "installer", branch);
}

void ensureSources()
{
    ensureDir(cloneDir);
    ensureDir(cloneDir~"/dmd");
    ensureDir(cloneDir~"/druntime");
    ensureDir(cloneDir~"/phobos");
    ensureDir(cloneDir~"/tools");
    ensureDir(cloneDir~"/dlang.org");
    ensureDir(cloneDir~"/installer");
}

void cleanAll()
{
    cleanAll(Bits.bits32);
    if(makefile != makefile64)
        cleanAll(Bits.bits64);
}

void cleanAll(Bits bits)
{
    auto targetMakefile = bits == Bits.bits32? makefile : makefile64;
    auto bitsStr        = bits == Bits.bits32? "32" : "64";
    auto bitsDisplay = toString(bits);
    auto makeModel = " MODEL="~bitsStr;
    auto hideStdout = verbose? "" : " > "~devNull;

    // Skip 64-bit tools when not using separate bin32/bin64 dirs
    if(useBitsSuffix || bits == Bits.bits32)
    {
        infoMsg("Cleaning DMD "~bitsDisplay);
        changeDir(cloneDir~"/dmd/src");
        run(make~makeModel~" clean -f "~targetMakefile~hideStdout);
    }
    
    infoMsg("Cleaning Druntime "~bitsDisplay);
    changeDir(cloneDir~"/druntime");
    run(make~makeModel~" clean -f "~targetMakefile~hideStdout);

    infoMsg("Cleaning Phobos "~bitsDisplay);
    changeDir(cloneDir~"/phobos");
    run(make~makeModel~" clean DOCSRC=../dlang.org DOC=doc -f "~targetMakefile~hideStdout);
    version(Windows)
        removeDir(cloneDir~"/phobos/generated");

    // Skip 64-bit tools when not using separate bin32/bin64 dirs
    if(useBitsSuffix || bits == Bits.bits32)
    {
        infoMsg("Cleaning Tools "~bitsDisplay);
        changeDir(cloneDir~"/tools");
        run(make~makeModel~" clean -f "~targetMakefile~hideStdout);
    }

    // Docs are bits-independent, so treat them as 32-bit only
    if(bits == Bits.bits32)
    {
        infoMsg("Cleaning dlang.org");
        changeDir(cloneDir~"/dlang.org");
        run(make~makeModel~" clean -f "~targetMakefile~hideStdout);
    }
}

void buildAll()
{
    buildAll(Bits.bits32);
    buildAll(Bits.bits64);
}

void buildAll(Bits bits)
{
    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);

    version(Windows)
        enum isWin = true;
    else
        enum isWin = false;
    
    auto targetMakefile = bits == Bits.bits32? makefile    : makefile64;
    auto libPhobos      = bits == Bits.bits32? libPhobos32 : libPhobos64;
    auto bitsStr = bits == Bits.bits32? "32" : "64";
    auto bitsDisplay = toString(bits);
    auto makeModel = " MODEL="~bitsStr;
    auto hideStdout = verbose? "" : " > "~devNull;
    
    // Skip 64-bit tools when not using separate bin32/bin64 dirs
    if(!isWin || bits == Bits.bits32)
    {
        infoMsg("Building DMD "~bitsDisplay);
        changeDir(cloneDir~"/dmd/src");
        run(make~makeModel~" dmd -f "~targetMakefile~hideStdout);
        copyFile(cloneDir~"/dmd/src/dmd"~exe, cloneDir~"/dmd/src/dmd"~bitsStr~exe);
        removeFiles(cloneDir~"/dmd/src", "*{"~obj~","~lib~"}", SpanMode.depth);
    }
    
    // Generate temporary sc.ini/dmd.conf
    version(Windows)
    {
        std.file.write(cloneDir~"/dmd/src/sc.ini", `
            [Environment]
            LIB="-I%@P%\..\..\phobos" "%@P%\..\..\druntime\lib"
            DFLAGS="-I%@P%\..\..\phobos" "-I%@P%\..\..\druntime\import"
        `.outdent().strip());
    }
    else version(Posix)
    {
        version(OSX)
            enum flags="";
        else
            enum flags=" -L--no-warn-search-mismatch -L--export-dynamic";
        
        std.file.write(cloneDir~"/dmd/src/dmd.conf", (`
            [Environment]
            DFLAGS=-I%@P%/../../phobos -I%@P%/../../druntime/src -L-L%@P%/../../phobos/generated/`~osDirName~`/release/`~bitsStr~` -L-L%@P%/../../druntime/lib`~flags~`
        `).outdent().strip());
    }
    else
        static assert(false, "Unsupported platform");
    
    infoMsg("Building Druntime "~bitsDisplay);
    changeDir(cloneDir~"/druntime");
    run(make~makeModel~" DMD=../dmd/src/dmd -f "~targetMakefile~hideStdout);
    removeFiles(cloneDir~"/druntime", "*{"~obj~"}", SpanMode.depth,
        file => !file.baseName.startsWith("gcstub", "minit"));

    infoMsg("Building Phobos "~bitsDisplay);
    changeDir(cloneDir~"/phobos");
    run(make~makeModel~" DMD=../dmd/src/dmd -f "~targetMakefile~hideStdout);

    version(OSX)
    {
        if(bits == Bits.bits64)
        {
            infoMsg("Building Phobos Universal Binary");
            changeDir(cloneDir~"/phobos");
            run(make~makeModel~" libphobos2.a DMD=../dmd/src/dmd -f "~targetMakefile~hideStdout);
        }
    }

    version(Windows)
    {
        makeDir(cloneDir~"/phobos/generated/windows/release/"~bitsStr);
        copyFile(
            cloneDir~"/phobos/"~libPhobos~lib,
            cloneDir~"/phobos/generated/windows/release/"~bitsStr~"/"~libPhobos~lib
        );
    }
    removeFiles(cloneDir~"/phobos", "*{"~obj~"}", SpanMode.depth);
    
    // Docs are bits-independent, so treat them as 32-bit only
    if(bits == Bits.bits32)
    {
        version(Windows)
        {
            // Needed by chmgen to build a chm of the docs on Windows
            infoMsg("Getting curl Import Lib");
            changeDir(cloneDir~"/tools");
            run("get_dlibcurl32.bat "~libCurlVersion~hideStdout);
        }
        
        infoMsg("Building Druntime Docs");
        changeDir(cloneDir~"/druntime");
        run(make~makeModel~" doc DMD=../dmd/src/dmd DOCSRC=../dlang.org DOCDIR=../web/phobos-prerelease -f "~targetMakefile~hideStdout);

        infoMsg("Building Phobos Docs");
        changeDir(cloneDir~"/phobos");
        run(make~makeModel~" html DMD=../dmd/src/dmd DOCSRC=../dlang.org DOC=../web/phobos-prerelease -f "~targetMakefile~hideStdout);

        infoMsg("Building dlang.org");
        version(Posix)
        {
            // Backwards compatability with older versions of the makefile
            auto oldDirName = cloneDir~"/d-programming-language.org";
            if(!exists(oldDirName))
                symlink(cloneDir~"/dlang.org", oldDirName);
        }
        changeDir(cloneDir~"/dlang.org");
        makeDir("doc");
        version(Posix)
            auto dlangOrgTarget = " html";
        else version(Windows)
            auto dlangOrgTarget = "";
        else
            static assert(false, "Unsupported platform");
        run(make~makeModel~" DMD=../dmd/src/dmd -f "~targetMakefile~dlangOrgTarget~hideStdout);
        version(Windows)
        {
            copyDir(cloneDir~"/web/phobos-prerelease", cloneDir~"/dlang.org/phobos");
            copyFile(cloneDir~"/tools/dlibcurl32-"~libCurlVersion~"/libcurl.lib", "./curl.lib");
            copyDir(cloneDir~"/tools/dlibcurl32-"~libCurlVersion, ".", file => file.endsWith(".dll"));
            run(make~makeModel~" chm DMD=../dmd/src/dmd DOCSRC=../dlang.org DOCDIR=../web/phobos-prerelease -f "~targetMakefile~hideStdout);
        }

        // Copy phobos docs into dlang.org docs directory, because
        // dman's posix makefile requires it.
        copyDir(cloneDir~"/web/phobos-prerelease", cloneDir~"/"~generatedDocs~"/phobos");
    }
    
    // Skip 64-bit tools when not using separate bin32/bin64 dirs
    if(!isWin || bits == Bits.bits32)
    {
        infoMsg("Building Tools "~bitsDisplay);
        changeDir(cloneDir~"/tools");
        run(make~makeModel~" rdmd      DMD=../dmd/src/dmd -f "~targetMakefile~hideStdout);
        run(make~makeModel~" ddemangle DMD=../dmd/src/dmd -f "~targetMakefile~hideStdout);
        run(make~makeModel~" findtags  DMD=../dmd/src/dmd -f "~targetMakefile~hideStdout);
        run(make~makeModel~" dustmite  DMD=../dmd/src/dmd -f "~targetMakefile~hideStdout);
        run(make~makeModel~" dman      DMD=../dmd/src/dmd DOC=../"~generatedDocs~" PHOBOSDOC=../"~generatedDocs~"/phobos -f "~targetMakefile~hideStdout);
        
        removeFiles(cloneDir~"/tools", "*.{"~obj~"}", SpanMode.depth);
    }
}

/// This doesn't use "make install" in order to avoid problems from
/// differences between 'posix.mak' and 'win*.mak'.
void createRelease(string branch)
{
    infoMsg("Generating release directory");

    removeDir(releaseDir);
    
    // Copy extras, if any
    if(customExtrasDir != "")
        copyDir(customExtrasDir, releaseDir);

    if(exists(allExtrasDir)) copyDir(allExtrasDir, releaseDir);
    if(exists( osExtrasDir)) copyDir( osExtrasDir, releaseDir);
    
    // Copy sources (should cppunit be omitted??)
    auto dmdSrcFilter = (string a) => !a.match("^cppunit[^/]*/");
    copyDirVersioned(cloneDir~"/dmd/src",  releaseDir~"/dmd2/src/dmd",      a => dmdSrcFilter(a));
    copyDirVersioned(cloneDir~"/druntime", releaseDir~"/dmd2/src/druntime", a => a != ".gitignore");
    copyDirVersioned(cloneDir~"/phobos",   releaseDir~"/dmd2/src/phobos",   a => a != ".gitignore");

    copyDir(cloneDir~"/druntime/doc",    releaseDir~"/dmd2/src/druntime/doc");
    copyDir(cloneDir~"/druntime/import", releaseDir~"/dmd2/src/druntime/import");
    copyFile(cloneDir~"/dmd/VERSION",    releaseDir~"/dmd2/src/VERSION");
    
    // Copy documentation
    auto dlangFilter = (string a) =>
        !a.startsWith("images/original/") &&
        ( a.endsWith(".html") || a.startsWith("css/", "images/", "js/") );
    copyDir(cloneDir~"/"~generatedDocs, releaseDir~"/dmd2/html/d", a => dlangFilter(a));
    copyDirVersioned(cloneDir~"/dmd/samples",  releaseDir~"/dmd2/samples/d");
    copyDirVersioned(cloneDir~"/dmd/docs/man", releaseDir~"/dmd2/man");
    makeDir(releaseDir~"/dmd2/html/d/zlib");
    copyFile(cloneDir~"/phobos/etc/c/zlib/ChangeLog", releaseDir~"/dmd2/html/d/zlib/ChangeLog");
    copyFile(cloneDir~"/phobos/etc/c/zlib/README",    releaseDir~"/dmd2/html/d/zlib/README");
    copyFile(cloneDir~"/phobos/etc/c/zlib/zlib.3",    releaseDir~"/dmd2/html/d/zlib/zlib.3");
    
    // Copy lib
    version(OSX)
        copyFile(cloneDir~"/phobos/generated/"~osDirName~"/release/libphobos2.a", releaseLib32Dir~"/libphobos2.a");
    else
    {
        // Generated lib dir contains an empty "etc/c/zlib" that we shouldn't include.
        auto excludeEtc = delegate bool(string file) => !file.startsWith("etc/");
        copyDir(cloneDir~"/phobos/generated/"~osDirName~"/release/32", releaseLib32Dir, excludeEtc);
        version(Windows)
        {
            copyDir(cloneDir~"/phobos/generated/"~osDirName~"/release/64", releaseLib64Dir, excludeEtc);
            copyFile(cloneDir~"/druntime/lib/gcstub.obj",   releaseLib32Dir~"/gcstub.obj");
            copyFile(cloneDir~"/druntime/lib/gcstub64.obj", releaseLib32Dir~"/gcstub64.obj");
        }
    }
    
    // Copy bin32
    version(OSX) {} else // OSX doesn't include 32-bit tools
    {
        copyFile(cloneDir~"/dmd/src/dmd32"~exe, releaseBin32Dir~"/dmd"~exe);
        copyDir(cloneDir~"/tools/generated/"~osDirName~"/32", releaseBin32Dir, file => !file.endsWith(obj));
    }
    
    // Copy bin64
    version(Windows) {} else // Win doesn't include 64-bit tools
    {
        copyFile(cloneDir~"/dmd/src/dmd64"~exe, releaseBin64Dir~"/dmd"~exe);
        copyDir(cloneDir~"/tools/generated/"~osDirName~"/64", releaseBin64Dir, file => !file.endsWith(obj));
    }
    
    verifyExtras();
}

void verifyExtras()
{
    infoMsg("Ensuring non-versioned support files exist");
        
    version(Windows)
    {
        auto files = [
            releaseBin32Dir~"/lib.exe",
            releaseBin32Dir~"/link.exe",
            releaseBin32Dir~"/make.exe",
            releaseBin32Dir~"/replace.exe",
            releaseBin32Dir~"/shell.exe",
            releaseBin32Dir~"/windbg.exe",
            releaseBin32Dir~"/dm.dll",
            releaseBin32Dir~"/eecxxx86.dll",
            releaseBin32Dir~"/emx86.dll",
            releaseBin32Dir~"/mspdb41.dll",
            releaseBin32Dir~"/shcv.dll",
            releaseBin32Dir~"/tlloc.dll",

            releaseLib32Dir~"/advapi32.lib",
            releaseLib32Dir~"/COMCTL32.lib",
            releaseLib32Dir~"/comdlg32.lib",
            releaseLib32Dir~"/CTL3D32.lib",
            releaseLib32Dir~"/gdi32.lib",
            releaseLib32Dir~"/kernel32.lib",
            releaseLib32Dir~"/ODBC32.lib",
            releaseLib32Dir~"/ole32.lib",
            releaseLib32Dir~"/OLEAUT32.lib",
            releaseLib32Dir~"/rpcrt4.lib",
            releaseLib32Dir~"/shell32.lib",
            releaseLib32Dir~"/snn.lib",
            releaseLib32Dir~"/user32.lib",
            releaseLib32Dir~"/uuid.lib",
            releaseLib32Dir~"/winmm.lib",
            releaseLib32Dir~"/winspool.lib",
            releaseLib32Dir~"/WS2_32.lib",
            releaseLib32Dir~"/wsock32.lib",
        ];
    }
    else version(linux)
    {
        auto files = [
            releaseBin32Dir~"/dumpobj",
            releaseBin32Dir~"/obj2asm",

            releaseBin64Dir~"/dumpobj",
            releaseBin64Dir~"/obj2asm",
        ];
    }
    else version(OSX)
    {
        auto files = [
            releaseBin32Dir~"/dumpobj",
            releaseBin32Dir~"/obj2asm",
            releaseBin32Dir~"/shell",
        ];
    }
    else version(FreeBSD)
    {
        auto files = [
            releaseBin32Dir~"/dumpobj",
            releaseBin32Dir~"/obj2asm",
            releaseBin32Dir~"/shell",
        ];
    }
    else
        string[] files;
    

    bool filesMissing = false;
    foreach(file; files)
    {
        if(!exists(file) || !isFile(file))
        {
            if(!filesMissing)
            {
                errorMsg("The following files are missing:");
                filesMissing = true;
            }
            
            stderr.writeln(displayPath(file));
        }
    }
    
    if(filesMissing)
    {
        fail(
            "The above files were missing from the appropriate dirs:\n"~
            displayPath(customExtrasDir ~ releaseBin32Dir.chompPrefix(releaseDir))~"\n"~
            displayPath(customExtrasDir ~ releaseLib32Dir.chompPrefix(releaseDir))~"\n"~
            displayPath(customExtrasDir ~ releaseBin64Dir.chompPrefix(releaseDir))~"\n"~
            displayPath(customExtrasDir ~ releaseLib64Dir.chompPrefix(releaseDir))
        );
    }
}

void createZip(string branch)
{
    auto archiveName = baseName(releaseDir)~".zip";
    archiveZip(releaseDir~"/dmd2", archiveName);
}

void create7z(string branch)
{
    auto archiveName = baseName(releaseDir)~".7z";
    archive7z(releaseDir~"/dmd2", archiveName);
}

void extractOsArchives(string branch)
{
    auto outputDir = "dmd."~branch;
    removeDir(outputDir);
    makeDir(outputDir);
    
    foreach(osName; allOsDirNames)
    {
        auto archiveName = "dmd."~branch~"."~osName;

        auto archiveZip = archiveName~".zip";
        auto archive7z  = archiveName~".7z";

        if(exists(archive7z))
            extract(archive7z, outputDir);
        else if(exists(archiveZip))
            extract(archiveZip, outputDir);
    }
}

void createCombinedZip(string branch)
{
    auto dirName = "dmd."~branch;
    archiveZip(dirName~"/dmd2", dirName~".zip");
}

void createCombined7z(string branch)
{
    auto dirName = "dmd."~branch;
    archive7z(dirName~"/dmd2", dirName~".7z");
}

// Utils -----------------------

void verboseMsg(lazy string msg)
{
    if(verbose)
        infoMsg(msg);
}

void infoMsg(lazy string msg)
{
    if(!quiet)
        writeln(msg);
}

void errorMsg(string msg)
{
    stderr.writeln("create_dmd_release: Error: "~msg);
}

/// Ugly hack around the lack of an UnrecognizedOptionException
bool isUnrecognizedOptionException(Exception e)
{
    return e && e.msg.startsWith("Unrecognized option");
}

// Test assumptions made by isUnrecognizedOptionException
unittest
{
    bool bar;
    auto args = ["someapp", "--foo"];
    auto e = collectException!Exception(getopt(args, "bar", &bar));
    assert(
        isUnrecognizedOptionException(e),
        "getopt's behavior upon unrecognized options is not as expected"
    );
}

/// Cleanup a path for display to the user:
/// - Strip current directory prefix, if applicable. (ie, The current directory
///   from the user's perspective, not this program's internal current directory.)
/// - On windows: Convert slashes to backslash.
string displayPath(string path)
{
    version(Windows)
        path = path.replace("/", "\\");
    
    return chompPrefix(path, origDir ~ dirSeparator);
}

string quote(string str)
{
    version(Windows)
        return `"`~str~`"`;
    else
        return `'`~str~`'`;
}

// Filesystem Utils -----------------------

void ensureNotFile(string path)
{
    if(exists(path) && !isDir(path))
        fail("'"~path~"' is a file, not a directory");
}

void ensureDir(string path)
{
    if(!exists(path) || !isDir(path))
        fail("Directory not found: '"~path~"'");
}

/// Removes a file if it exists, otherwise do nothing
void removeFile(string path)
{
    if(exists(path))
        std.file.remove(path);
}

void removeFiles(string path, string pattern, SpanMode mode,
    bool delegate(string) filter)
{
    removeFiles(path, pattern, mode, true, filter);
}

void removeFiles(string path, string pattern, SpanMode mode,
    bool followSymlink = true, bool delegate(string) filter = null)
{
    if(mode == SpanMode.breadth)
        throw new Exception("removeFiles can only take SpanMode of 'depth' or 'shallow'");
    
    auto displaySuffix = mode==SpanMode.shallow? "" : "/*";
    verboseMsg("Deleting '"~pattern~"' from '"~displayPath(path~displaySuffix)~"'");

    // Needed to generate 'relativePath' correctly.
    path = path.replace("\\", "/");
    if(!path.endsWith("/", "\\"))
        path ~= "/";

    foreach(DirEntry entry; dirEntries(path[0..$-1], pattern, mode, false))
    {
        if(entry.isFile)
        {
            auto relativePath = entry.replace("\\", "/").chompPrefix(path);

            if(!filter || filter(relativePath))
            {
                verboseMsg("    " ~ displayPath(relativePath));
                entry.remove();
            }
            else if(filter)
                verboseMsg("    Skipping: " ~ displayPath(relativePath));
        }
    }
}

/// Remove entire directory tree. If it doesn't exist, do nothing.
void removeDir(string path)
{
    if(exists(path))
    {
        verboseMsg("Removing dir: "~displayPath(path));
        
        void removeDirFailed()
        {
            fail(
                "Failed to remove directory: "~displayPath(path)~"\n"~
                "    A process may still holding an open handle within the directory.\n"~
                "    Either delete the directory manually or try again later."
            );
        }
        
        try
        {
            version(Windows)
                system("rmdir /S /Q "~quote(path));
            else
                system("rm -rf "~quote(path));
        }
        catch(Exception e)
            removeDirFailed();

        if(exists(path))
            removeDirFailed();
    }
}

/// Like mkdirRecurse, but no error if directory already exists.
void makeDir(string path)
{
    if(!exists(path))
    {
        verboseMsg("Creating dir: "~displayPath(path));
        mkdirRecurse(path);
    }
}

void changeDir(string path)
{
    verboseMsg("Entering dir: "~displayPath(path));

    try
        chdir(path);
    catch(FileException e)
        fail(e.msg);
}

/// Copy files, creating destination directories as needed
void copyFiles(string[] relativePaths, string srcPrefix, string destPrefix, bool delegate(string) filter = null)
{
    verboseMsg("Copying from '"~displayPath(srcPrefix)~"' to '"~displayPath(destPrefix)~"'");
    foreach(path; relativePaths)
    {
        if(filter && !filter(path))
            continue;
        
        auto srcPath  = buildPath(srcPrefix,  path);
        auto destPath = buildPath(destPrefix, path);

        makeDir(dirName(destPath));

        verboseMsg("    "~path);
        copy(srcPath, destPath);
    }
}

/// Recursively copy the contents of a directory, excluding anything
/// untracked or ignored by git.
void copyDirVersioned(string src, string dest, bool delegate(string) filter = null)
{
    auto versionedFiles = gitVersionedFiles(src);
    copyFiles(versionedFiles, src, dest, filter);
}

/// Recursively copy contents of 'src' directory into 'dest' directory.
/// Directory 'dest' will be created if it doesn't exist.
/// Takes optional delegate to filter out any files to not copy.
void copyDir(string src, string dest, bool delegate(string) filter = null)
{
    verboseMsg("Copying from '"~displayPath(src)~"' to '"~displayPath(dest)~"'");

    // Needed to generate 'relativePath' correctly.
    src = src.replace("\\", "/");
    if(!src.endsWith("/", "\\"))
        src ~= "/";
    
    makeDir(dest);
    foreach(DirEntry entry; dirEntries(src[0..$-1], SpanMode.breadth, false))
    {
        auto relativePath = entry.name.replace("\\", "/").chompPrefix(src);

        if(!filter || filter(relativePath))
        {
            verboseMsg("    " ~ displayPath(relativePath));
            
            auto destPath = buildPath(dest, relativePath);
            auto srcPath  = buildPath(src,  relativePath);
            
            version(Posix)
            {
                if(entry.isSymlink)
                {
                    run("ln -P "~srcPath~" "~destPath);
                    continue;
                }
            }
            
            if(entry.isDir)
                makeDir(destPath);
            else
            {
                makeDir(dirName(destPath));
                copy(srcPath, destPath);
            }
        }
        else if(filter)
            verboseMsg("    Skipping: " ~ displayPath(relativePath));
    }
}

/// Like std.file.copy, but with verbose logging and auto-creates dest directory
void copyFile(string src, string dest)
{
    verboseMsg("Copying from '"~displayPath(src)~"' to '"~displayPath(dest)~"'");
    makeDir(dirName(dest));
    copy(src, dest);
}

void copyFileIfExists(string src, string dest)
{
    if(exists(src))
        copyFile(src, dest);
}

// External Tools -----------------------

/// Check if running "tool --help" succeeds. If not, returns false.
bool checkTool(string cmd, string cmdArgs="--help", string regexMatch=null)
{
    auto cmdLine = cmd~" "~cmdArgs;
    verboseMsg("Checking: "~cmdLine);

    try
    {
        auto result = shell(cmdLine~" 2> "~devNull);
        if(regexMatch != "" && !match(result, regex(regexMatch, "s")))
            return false;
    }
    catch(Exception e)
        return false;
    
    return true;
}

/// Check if running "tool --help" succeeds. If not, throws Fail.
void ensureTool(string cmd, string cmdArgs="--help", string regexMatch=null)
{
    if(!checkTool(cmd, cmdArgs, regexMatch))
        fail("Problem running '"~cmd~"'. Please make sure it's correctly installed.");
}

/// Like system(), but throws useful Fail message upon failure.
void run(string cmd)
{
    verboseMsg("Running: "~cmd);
    
    stdout.flush();
    stderr.flush();
    
    auto errlevel = system(cmd);
    if(errlevel != 0)
        fail("Command failed (ran from dir '"~displayPath(getcwd())~"'): "~cmd);
}

/// Like run(), but captures the standard output and returns it.
string runCapture(string cmd)
{
    verboseMsg("Running: "~cmd);
    
    stdout.flush();
    stderr.flush();
    
    auto result = executeShell(cmd);
    if(result.status != 0)
        fail("Command failed (ran from dir '"~displayPath(getcwd())~"'): "~cmd);
    
    return result.output;
}

/// Clone a git repository to a specific path. Optionally to a
/// specific branch (default is master).
///
/// Requires a command-line git client.
void gitClone(string repo, string path, string branch=null)
{
    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);
    removeDir(path);
    makeDir(path);
    changeDir(path);
    
    infoMsg("Cloning: "~repo);
    auto quietSwitch = verbose? "" : "-q ";
    run("git clone "~quietSwitch~quote(repo)~" .");
    if(branch != "")
        run("git checkout "~quietSwitch~quote(branch));
}

string[] gitVersionedFiles(string path)
{
    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);
    changeDir(path);
    
    Appender!(string[]) versionedFiles;
    auto gitOutput = runCapture("git ls-files").strip();
    foreach(filename; gitOutput.splitter("\n"))
        versionedFiles.put(filename);
    
    return versionedFiles.data;
}

void extract(string archive, string outputDir)
{
    infoMsg("Extracting "~displayPath(archive));

    auto hideStdout = verbose? "" : " > "~devNull;

    version(Posix)
        auto tool = tool7z;
    else version(Windows)
        auto tool = has7z? tool7z : tool7zArchiveDir~"/"~tool7z;
    else
        static assert(false, "Unsupported system");

    run(tool~" x -y -bd "~quote("-o"~outputDir)~" "~quote(archive)~hideStdout);
}

void archiveZip(string inputDir, string archive)
{
    archive = absolutePath(archive);
    infoMsg("Generating "~displayPath(archive));
    
    if(exists(archive))
        remove(archive);

    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);
    
    changeDir(dirName(inputDir));
    auto quietSwitch = verbose? "" : "-q ";

    version(Posix)
    {
        auto tool = "zip";
        auto switches = "-r9y ";
    }
    else version(Windows)
    {
        auto tool = hasZip? "zip" : zipArchiveDir~"/zip";
        auto switches = "-r9 ";
    }
    else
        static assert(false, "Unsupported system");

    run(tool~" "~switches~quietSwitch~archive~" "~baseName(inputDir));
}

void archive7z(string inputDir, string archive)
{
    archive = absolutePath(archive);
    infoMsg("Generating "~displayPath(archive));

    if(exists(archive))
        remove(archive);

    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);
    
    changeDir(dirName(inputDir));
    auto hideStdout = verbose? "" : " > "~devNull;

    version(Posix)
        auto tool = tool7z;
    else version(Windows)
        auto tool = has7z? tool7z : tool7zArchiveDir~"/"~tool7z;
    else
        static assert(false, "Unsupported system");

    run(tool~" a -r -bd -mx=9 "~archive~" "~baseName(inputDir)~hideStdout);
}

void initTools()
{
    // Don't try to auto-install zip/7z on Posix because:
    // - It's usually trivial compared to Windows.
    // - AFAIK, it's not always as trivial to do a hygenic non-system-wide install.
    // - The actual command needed is highly system-specific.
    // Ie, on Posix: Easy for the user to install, but hard for us to install.

    version(Windows)
    {
        if(shouldZip)
            initZip();

        if(should7z)
            init7z();
    }
}

version(Windows)
{
    void initBasicTools()
    {
        static gotBasicTools = false;
        if(gotBasicTools)
            return;
        
        initDownloader();
        initUnzip();
        
        gotBasicTools = true;
    }

    void initDownloader()
    {
        dloadToolPath = cloneDir~"/"~dloadToolFilename;
        std.file.write(dloadToolPath, dloadToolContent);
    }
    
    void setupTool(string url, string targetDir, string targetName)
    {
        // Download
        mkdir(targetDir);
        download(url, targetDir~"/"~targetName);
        
        // Goto dir
        auto saveDir = getcwd();
        scope(exit) changeDir(saveDir);
        changeDir(targetDir);
        
        // Extract
        if(targetName.endsWith(".zip"))
            unzip(targetName);
        else
        {
            // Self-extracting archive
            infoMsg("Self-Extracting: "~targetName);
            auto hideOutput = verbose? "" : " > "~devNull~" 2> "~devNull;
            run(targetName~hideOutput);
        }
    }
    
    void initUnzip()
    {
        if(hasUnzip)
            return;
        
        if(!checkTool(unzipArchiveDir~"/unzip", "--help", unzipBannerRegex))
            setupTool(unzipUrl, unzipArchiveDir, unzipArchiveName);
    }

    void initZip()
    {
        if(hasZip)
            return;
        
        if(!checkTool(zipArchiveDir~"/zip", "-v", zipBannerRegex))
        {
            initBasicTools();
            setupTool(zipUrl, zipArchiveDir, zipArchiveName);
        }
    }

    void init7z()
    {
        if(has7z)
            return;
        
        if(!checkTool(tool7zArchiveDir~"/"~tool7z))
        {
            initBasicTools();
            setupTool(tool7zUrl, tool7zArchiveDir, tool7zArchiveName);
        }
    }

    void download(string url, string target)
    {
        infoMsg("Downloading: "~url);
        run("cscript //Nologo "~quote(dloadToolPath)~" "~quote(url)~" "~quote(target));
    }

    void unzip(string path)
    {
        infoMsg("Unzipping: "~path);
        
        auto saveDir = getcwd();
        scope(exit) changeDir(saveDir);
        changeDir(dirName(path));
        
        auto unzipTool = hasUnzip? "unzip" : unzipArchiveDir~"/unzip";
        run(unzipTool~" -q "~quote(baseName(path)));
    }
}
