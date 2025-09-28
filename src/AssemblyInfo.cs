using System.Reflection;
using System.Runtime.Versioning;
using System.Windows;

// Version information - These will be replaced by build scripts
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0+dev")]

// Assembly metadata
[assembly: AssemblyTitle("LiveCaptions Translator")]
[assembly: AssemblyDescription("A real-time speech translation tool based on Windows LiveCaptions")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("SakiRinn and Contributors")]
[assembly: AssemblyProduct("LiveCaptions Translator")]
[assembly: AssemblyCopyright("Copyright © 2024 SakiRinn and other contributors")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyCulture("")]

// Build information - These will be set by the build system
[assembly: AssemblyMetadata("GitCommitHash", "unknown")]
[assembly: AssemblyMetadata("GitBranch", "unknown")]
[assembly: AssemblyMetadata("BuildTimestamp", "unknown")]
[assembly: AssemblyMetadata("BuildConfiguration", "unknown")]

[assembly: SupportedOSPlatform("windows7.0")]
[assembly: ThemeInfo(
    ResourceDictionaryLocation.None,            //where theme specific resource dictionaries are located
                                                //(used if a resource is not found in the page,
                                                // or application resource dictionaries)
    ResourceDictionaryLocation.SourceAssembly   //where the generic resource dictionary is located
                                                //(used if a resource is not found in the page,
                                                // app, or any theme specific resource dictionaries)
)]
