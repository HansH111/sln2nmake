#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;

# ------------------------------------------------------------------- #
# Parse command line parameters
#
# ------------------------------------------------------------------- #
# Params: \%hash, $switches, $options
#
my %PARAM;
my $switches="-v ";             # switches seperate by spaces
my $options="-pl -conf -opts "; # same for with additional params
$PARAM{opts}='';                # default values
$PARAM{pl}='x64';               # default platform = x64
$PARAM{conf}='Release';         # default config = release
$PARAM{v}=0;
show_syntax()     if (CMDLINE_parse(\%PARAM,$switches,$options)==-1);
show_syntax()     if ($#ARGV < 0 || ! -f $ARGV[0]);
my $sln_file = $ARGV[0];
my $prjnm = $ARGV[1] || '';
print "# sln=$sln_file  prj=$prjnm\n";

my $CONFIG        = $PARAM{conf};    # Options: Release, Debug
my $PLATFORM      = $PARAM{pl};      # Options: x64, Win32
my $TARGET_CONFIG = "$CONFIG|$PLATFORM";

my $SOLUTION_DIR = $ENV{PWD} || '';
$SOLUTION_DIR = qx{pwd}     if ($SOLUTION_DIR eq '');
$SOLUTION_DIR =~ s/[\r\n\s]+$//;
$SOLUTION_DIR =~ s|/|\\|g;  # Convert to backslashes

my $OUT_DIR='';
$OUT_DIR .= $PLATFORM."\\"   if ($PLATFORM eq 'x64');
$OUT_DIR .= "Release";               

# Main execution
my %projects = read_sln($sln_file);
foreach my $proj_name (keys %projects) {
    read_project_file($proj_name, $projects{$proj_name});
    write_project_makefile($proj_name, $projects{$proj_name});
}
write_solution_makefile(\%projects);
print Dumper(\%projects)  if ($PARAM{v} > 2);

print "\n";
print "To build all projects, run: nmake\n";
print "To clean all projects, run: nmake clean\n";
print "To build a single project, run: nmake /f Makefile_<project>\n";
print "Note: Run in a Visual Studio command prompt configured for $PLATFORM.\n";
exit 0;


# Function to read the .sln file and parse dependencies
sub read_sln {
    my ($sln_file) = @_;
    my %projects;
    my %guid_to_name=();
    my $in_dep_section = 0;
    my $current_proj='';

    open my $fh, '<', $sln_file or die "Cannot open $sln_file: $!\n";
    while (<$fh>) {
        chomp;
        if (/Project\("\{[^}]+\}"\) = "([^"]+)", "([^"]+\.(vcproj|vcxproj))", "{([^}]+)/) {
			$current_proj='';
            my ($proj_name, $proj_rel_path, undef, $guid) = ($1, $2, $3, $4);
			next if ($prjnm ne '' && $prjnm ne $proj_name);
            my $proj_path = $SOLUTION_DIR."\\".$proj_rel_path;
            $proj_path =~ s/\\/\//g;
            $projects{$proj_name} = { proj_path => $proj_path, guid => $3, dependencies => [], is_vcxproj => ($proj_rel_path =~ /\.vcxproj$/i) };
            $guid_to_name{$guid} = $proj_name;
	        $current_proj = $proj_name;
        }
        elsif (/ProjectSection\(ProjectDependencies\)/) {
            $in_dep_section = 1;
        }
        elsif (/EndProjectSection/) {
            $in_dep_section = 0;
        }
        elsif ($in_dep_section && /\{([^}]+)\} = \{[^}]+\}/) {
			my $pa=$projects{$current_proj}->{dependencies};
			push(@$pa, $1); 
        }
    }
    close $fh;
    die "  No projects found in $sln_file\n" unless keys %projects;
    # resolve guid and replace them with the saved projnames
    foreach my $projnm (keys %projects) {
    	my $pa=$projects{$projnm}->{dependencies};
	    for (my $i=0; $i<=$#$pa; $i++) {
           my $guid=$pa->[$i];
           my $nm=$guid_to_name{$guid} || '';
           printf "  proj %-12s  dep %-12s (= %s)\n",$projnm,$nm,$guid  if ($PARAM{v});
           $pa->[$i]=$nm;
        }
	}
    print "  Parsed $sln_file successfully with dependencies\n";
    return %projects;
}

# Function to read a .vcproj or .vcxproj file
sub read_project_file {
    my ($proj_name, $proj_ref) = @_;
    my $proj_path = $proj_ref->{proj_path};
    die "  Project file '$proj_path' not found\n" unless -f $proj_path;

    my $data = parse_xmlfile($proj_path);
    return     if ($data == 0);

    if ($proj_ref->{is_vcxproj}) {
        read_vcxproj($proj_name, $proj_ref, $data);
    } else {
        read_vcproj($proj_name, $proj_ref, $data);
    }
}

# Function to read a .vcproj file
sub read_vcproj {
    my ($proj_name, $proj_ref, $data) = @_;
    my $root = $data->{VisualStudioProject};
    my $config;
    foreach my $conf (@{$root->{Configurations}->{Configuration}}) {
        if ($conf->{Name} eq $TARGET_CONFIG) {
            $config = $conf;
			print "- conf.name=$TARGET_CONFIG\n";
            last;
        }
    }
    die "  Configuration '$TARGET_CONFIG' not found in $proj_ref->{proj_path}\n" unless $config;

    my ($compiler_tool, $linker_tool, $librarian_tool);
    foreach my $tool (@{$config->{Tool}}) {
        if ($tool->{Name} eq 'VCCLCompilerTool') { $compiler_tool = $tool; }
        elsif ($tool->{Name} eq 'VCLinkerTool') { $linker_tool = $tool; }
        elsif ($tool->{Name} eq 'VCLibrarianTool') { $librarian_tool = $tool; }
    }
    warn "  VCCLCompilerTool not found in $proj_ref->{proj_path}\n" unless $compiler_tool;

    my @source_files;
    foreach my $filter (@{$root->{Files}->{Filter}}) {
        if ($filter->{Name} eq 'Source Files') {
            my $files = $filter->{File};
            $files = [$files] unless ref $files eq 'ARRAY';  # Ensure array ref
            foreach my $file (@$files) {
                my $rel_path = $file->{RelativePath};
                push @source_files, $proj_name."\\".$rel_path if $rel_path =~ /\.(c|cpp|cxx)$/i;
            }
        }
    }
    die "  No source files found in 'Source Files' filter of $proj_ref->{proj_path}\n" unless @source_files;

    my $intermediate_dir = $config->{IntermediateDirectory} || "$PLATFORM/$CONFIG";
    $intermediate_dir =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/g;
    my @object_files;
    for my $source_file (@source_files) {
        my ($volume, $dir, $file_name) = splitpath($source_file);
        $file_name =~ s/\.[^.]+$//;
        my $obj_file = $intermediate_dir."\\".$file_name.".obj";
        push @object_files, $obj_file;
    }

    my $config_type = $config->{ConfigurationType} || 4;
    my $output_file = ($config_type == 4)
        ? ($librarian_tool && $librarian_tool->{OutputFile} || "$config->{OutputDirectory}\\$root->{Name}.lib")
        : ($linker_tool && $linker_tool->{OutputFile} || "$config->{OutputDirectory}\\$root->{Name}" . ($config_type == 1 ? '.exe' : '.dll'));
    $output_file =~ s/\$\(SolutionDir\)/$SOLUTION_DIR\\/g;

    $proj_ref->{compiler_tool} = $compiler_tool;
    $proj_ref->{linker_tool} = $linker_tool;
    $proj_ref->{librarian_tool} = $librarian_tool;
    $proj_ref->{source_files} = \@source_files;
    $proj_ref->{object_files} = \@object_files;
    $proj_ref->{output_file} = $output_file;
    $proj_ref->{config_type} = $config_type;
}

# Function to read a .vcxproj file
sub read_vcxproj {
    my ($proj_name, $proj_ref, $data) = @_;
    my $root = $data->{Project};

    my ($compiler_tool, $linker_tool, $librarian_tool, $out_dir, $int_dir, $config_type);
    my $prop_groups = $root->{PropertyGroup};
    $prop_groups = [$prop_groups] unless ref $prop_groups eq 'ARRAY';
    foreach my $prop_group (@$prop_groups) {
        next unless $prop_group->{Condition} && $prop_group->{Condition} =~ /\Q'$TARGET_CONFIG'\E/;
        $out_dir = $prop_group->{OutDir} if $prop_group->{OutDir};
        $int_dir = $prop_group->{IntDir} if $prop_group->{IntDir};
        $config_type = $prop_group->{ConfigurationType} if $prop_group->{ConfigurationType};
    }

    my $item_def_groups = $root->{ItemDefinitionGroup};
    $item_def_groups = [$item_def_groups] unless ref $item_def_groups eq 'ARRAY';
    foreach my $item_def_group (@$item_def_groups) {
        next unless $item_def_group->{Condition} && $item_def_group->{Condition} =~ /\Q'$TARGET_CONFIG'\E/;
        $compiler_tool  = $item_def_group->{ClCompile} if $item_def_group->{ClCompile};
        $linker_tool    = $item_def_group->{Link}      if $item_def_group->{Link};
        $librarian_tool = $item_def_group->{Lib}       if $item_def_group->{Lib};
    }
    warn "  ClCompile not found for $TARGET_CONFIG in $proj_ref->{proj_path}\n" unless $compiler_tool;

    my @source_files;
    my $item_groups = $root->{ItemGroup};
    $item_groups = [$item_groups] unless ref $item_groups eq 'ARRAY';
    foreach my $item_group (@$item_groups) {
        my $cl_compiles = $item_group->{ClCompile};
        $cl_compiles = [$cl_compiles] unless ref $cl_compiles eq 'ARRAY';
        foreach my $cl_compile (@$cl_compiles) {
            my $include = $cl_compile->{Include};
            push @source_files, $include if $include && $include =~ /\.(c|cpp|cxx)$/i;
        }
    }
    die "  No source files found in $proj_ref->{proj_path}\n" unless @source_files;

    $int_dir ||= "$PLATFORM/$CONFIG/";
    $out_dir ||= "$SOLUTION_DIR/$PLATFORM/$CONFIG/";
    $int_dir =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/g;
    $out_dir =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/g;
    my @object_files;
    for my $source_file (@source_files) {
        my ($volume, $dir, $file_name) = splitpath($source_file);
        $file_name =~ s/\.[^.]+$//;
        my $obj_file = "$int_dir\\$file_name.obj";
        push @object_files, $obj_file;
    }

    my %config_type_map = ('Application' => 1, 'DynamicLibrary' => 2, 'StaticLibrary' => 4);
    $config_type = $config_type_map{$config_type} || 4;
    my $output_file = ($config_type == 4)
        ? ($librarian_tool && $librarian_tool->{OutputFile} ? $librarian_tool->{OutputFile} : "$out_dir$proj_name.lib")
        : ($linker_tool && $linker_tool->{OutputFile} ? $linker_tool->{OutputFile} : "$out_dir$proj_name" . ($config_type == 1 ? '.exe' : '.dll'));
    $output_file =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/g;

    $proj_ref->{compiler_tool} = $compiler_tool;
    $proj_ref->{linker_tool} = $linker_tool;
    $proj_ref->{librarian_tool} = $librarian_tool;
    $proj_ref->{source_files} = \@source_files;
    $proj_ref->{object_files} = \@object_files;
    $proj_ref->{output_file} = $output_file;
    $proj_ref->{config_type} = $config_type;
}

sub splitpath {
    my ($path) = @_;
    # Some regexes we use for path splitting
    my $DRIVE_RX = '[a-zA-Z]:';
    my $UNC_RX = '(?:\\\\\\\\|//)[^\\\\/]+[\\\\/][^\\\\/]+';
    my $VOL_RX = "(?:$DRIVE_RX|$UNC_RX)";
    my ($volume,$directory,$file) = ('','','');
    $path =~ m{^ ( $VOL_RX ? )
                ( (?:.*[\\/](?:\.\.?\Z(?!\n))?)? )
                (.*)
             }sox;
    $volume    = $1;
    $directory = $2;
    $file      = $3;
    return ($volume,$directory,$file);
}

# Function to get compiler options
sub get_compiler_options {
    my ($tool) = @_;
    return [] unless $tool;

    my %option_map = (
        'Optimization' => { '0' => '/Od', '1' => '/O1', '2' => '/O2', '3' => '/Ox', 'MaxSpeed' => '/O2' },
        'EnableIntrinsicFunctions' => { 'true' => '/Oi', 'false' => '' },
        'AdditionalIncludeDirectories' => sub { join(' ', map { "/I$_" } split(/;/, shift =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/gr)) },
        'RuntimeLibrary' => { 
            'MultiThreaded' => '/MT', 'MultiThreadedDebug' => '/MTd', 
            'MultiThreadedDLL' => '/MD', 'MultiThreadedDebugDLL' => '/MDd',
            '0' => '/MT', '1' => '/MTd', '2' => '/MD', '3' => '/MDd'
        },
        'EnableFunctionLevelLinking' => { 'true' => '/Gy', 'false' => '' },
        'WarningLevel' => { '0' => '/W0', '1' => '/W1', '2' => '/W2', '3' => '/W3', '4' => '/W4' },
        'DebugInformationFormat' => { '0' => '', '1' => '/Z7', '2' => '/Zi', '3' => '/ZI' },
    );

    my @options = ('/c');
    while (my ($key, $value) = each %$tool) {
        next if $key eq 'Name';
        if (exists $option_map{$key}) {
            my $option = ref($option_map{$key}) eq 'CODE'
                ? $option_map{$key}->($value)
                : $option_map{$key}->{$value} || '';
            push @options, $option if $option;
        }
    }
    return \@options;
}

# Function to get linker options
sub get_linker_options {
    my ($tool, $is_dll) = @_;
    return [] unless $tool;
    $tool->{LinkTimeCodeGeneration}='1'	if (not exists $tool->{LinkTimeCodeGeneration});
    my $libdir=$tool->{AdditionalLibraryDirectories} || "\$(OutDir)";

    my %option_map = (
        'OutputFile' => sub { "/OUT:\"$_[0]\"" },
        'LinkIncremental' => { '1' => '/INCREMENTAL:NO', '2' => '/INCREMENTAL' },
        'GenerateDebugInformation' => { 'true' => '/DEBUG', 'false' => '' },
        'ProgramDatabaseFile' => sub { "/PDB:\"$_[0]\"" },
        'SubSystem' => { '1' => '/SUBSYSTEM:CONSOLE', '2' => '/SUBSYSTEM:WINDOWS', 'Console' => '/SUBSYSTEM:CONSOLE', 'Windows' => '/SUBSYSTEM:WINDOWS' },
        'TargetMachine' => { '1' => '/MACHINE:X86', '17' => '/MACHINE:X64', 'MachineX86' => '/MACHINE:X86', 'MachineX64' => '/MACHINE:X64' },
        'AdditionalDependencies' => sub { if (index($_[0],"\\") < 0) { $libdir."\\".$_[0] } else { $_[0] } },
        'IgnoreSpecificDefaultLibraries' => sub { join(' ', map { "/NODEFAULTLIB:$_" } split(/;/, $_[0])) },
        'ModuleDefinitionFile' => sub { "/DEF:\"$_[0]\"" },
        'EnableCOMDATFolding' => { 'true' => '/OPT:ICF', 'false' => '' },
        'OptimizeReferences' => { 'true' => '/OPT:REF', 'false' => '/OPT:NOREF' },
        'LinkTimeCodeGeneration' => { '1' => '/LTCG', '0' => '' },
        'EntryPointSymbol' => sub { "/ENTRY:$_[0]" },
        'BaseAddress' => sub { "/BASE:$_[0]" },
        'ImportLibrary' => sub { "/IMPLIB:\"$_[0]\"" },
    );

    my @options;
    while (my ($key, $value) = each %$tool) {
        next if $key eq 'Name';
        if (exists $option_map{$key}) {
            my $option = ref($option_map{$key}) eq 'CODE'
                ? $option_map{$key}->($value)
                : $option_map{$key}->{$value} || '';
            push @options, $option if $option;
        }
    }
    push @options, '/DLL' if $is_dll;
    push @options, 'kernel32.lib user32.lib' unless $tool->{AdditionalDependencies};
    return \@options;
}

# Function to get librarian options
sub get_librarian_options {
    my ($tool) = @_;
    return [] unless $tool;

    my %option_map = (
        'OutputFile' => sub { "/OUT:\"$_[0]\"" },
        'AdditionalDependencies' => sub { $_[0] },
        'AdditionalLibraryDirectories' => sub { join(' ', map { "/LIBPATH:\"$_\"" } split(/;/, shift =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/gr)) },
        'IgnoreSpecificDefaultLibraries' => sub { join(' ', map { "/NODEFAULTLIB:$_" } split(/;/, $_[0])) },
        'TargetMachine' => { '1' => '/MACHINE:X86', '17' => '/MACHINE:X64', 'MachineX86' => '/MACHINE:X86', 'MachineX64' => '/MACHINE:X64' },
    );

    my @options;
    while (my ($key, $value) = each %$tool) {
        next if $key eq 'Name';
        if (exists $option_map{$key}) {
            my $option = ref($option_map{$key}) eq 'CODE'
                ? $option_map{$key}->($value)
                : $option_map{$key}->{$value} || '';
            push @options, $option if $option;
        }
    }
    return \@options;
}

# Function to write project Makefile
sub write_project_makefile {
    my ($proj_name, $proj) = @_;
    my $makefile_name = "Makefile_${proj_name}";
    open my $fh, '>', $makefile_name or die "Cannot open $makefile_name for writing: $!\n";
    print $fh "# Generated Makefile for $proj_name ($sln_file, $TARGET_CONFIG)\n\n";

    print $fh "PlatformName = $PLATFORM\n";
    print $fh "ConfigurationName = $CONFIG\n";
	print $fh "OutDir = $OUT_DIR\n\n";
	
    print $fh "CC = cl.exe\n";
    print $fh "LINK = link.exe\n";
    print $fh "LIB = lib.exe\n\n";

    my $cflags = get_compiler_options($proj->{compiler_tool});
    print $fh "CFLAGS = ", join(' ', @$cflags), "\n";

    if ($proj->{config_type} != 4) {
        my $lflags = get_linker_options($proj->{linker_tool}, $proj->{config_type} == 2);
        print $fh "LFLAGS = ", join(' ', @$lflags), "\n";
    } else {
        my $libflags = get_librarian_options($proj->{librarian_tool});
        print $fh "LIBFLAGS = ", join(' ', @$libflags), "\n";
    }
    print $fh "OUT = $proj->{output_file}\n";
    print $fh "OBJ = ", join(" \\\n\t", @{$proj->{object_files}}), "\n";
    print $fh "\n";

    print $fh "all: \$(OUT)\n\n";
    if ($proj->{config_type} != 4) {
        print $fh "\$(OUT): \$(OBJ)\n";
        print $fh "\t\$(LINK) \$(LFLAGS) \$(OBJ) -out:\$(OUT)\n\n";
    } else {
        print $fh "\$(OUT): \$(OBJ)\n";
        print $fh "\t\$(LIB) \$(LIBFLAGS) -out:\$(OUT) \$(OBJ)\n\n";
    }

    for my $i (0..$#{$proj->{source_files}}) {
        my $source_file = $proj->{source_files}[$i];
        my $obj_file = $proj->{object_files}[$i];
        print $fh "$obj_file: $source_file\n";
        print $fh "\t\$(CC) \$(CFLAGS) $source_file -Fo$obj_file\n\n";
    }

    print $fh "clean:\n";
    my $extra_clean = ($proj->{config_type} == 2 && $proj->{linker_tool}->{ImportLibrary}) ? " $proj->{linker_tool}->{ImportLibrary}" : "";
    $extra_clean =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/g;
    print $fh "\tdel \$(OBJ) \$(OUT)$extra_clean\n";

    close $fh;
    print "  Generated $makefile_name\n";
}

# Function to write solution Makefile
sub write_solution_makefile {
    my ($projects_ref) = @_;
    open my $fh, '>', 'Makefile' or die "Cannot open Makefile for writing: $!\n";
    print $fh "# Generated Solution Makefile for $sln_file ($TARGET_CONFIG)\n\n";

    my @prjnms=(keys %$projects_ref), "\n\n";
    print $fh "ALL_PROJECTS = ".join(' ',@prjnms)."\n\n";
    print $fh "all: \$(ALL_PROJECTS)\n\n";

    foreach my $proj_name (keys %$projects_ref) {
        my $proj = $projects_ref->{$proj_name};
        my @deps;
        # print "- dep ".join(' ', @{$proj->{dependencies}})."\n";
        push @deps, map { $_ } @{$proj->{dependencies}};
#        if ($proj->{config_type} != 4) {
#            push @deps, map { my $implib = $projects_ref->{$_}->{linker_tool}->{ImportLibrary} || "$projects_ref->{$_}->{output_file}.lib"; $implib =~ s/\$\(SolutionDir\)/$SOLUTION_DIR/g; $implib } grep { $projects_ref->{$_}->{config_type} == 2 && !grep { $_ eq $projects_ref->{$_} } @{$proj->{dependencies}}} keys %$projects_ref;
#        }

        print $fh "$proj_name:", @deps ? " " . join(' ', @deps) : "", "\n";
        print $fh "\tnmake -f Makefile_${proj_name}\n\n";
    }

    print $fh "clean:\n";
    foreach my $proj_name (keys %$projects_ref) {
        print $fh "\tnmake -f Makefile_${proj_name} clean\n";
    }

    close $fh;
    print "# Generated Makefile\n";
}


# Parse XML file
sub parse_xmlfile {
    my $file = shift;

    # Handle file input
    my $xml;
    if ( ref $file ) {
        # Assume filehandle
        local $/ = undef;
        $xml = <$file>;
    } else {
        # Open file
        open my $fh, '<', $file or return 0;
        local $/ = undef;
        $xml = <$fh>;
        close $fh;
    }

    # Parse the XML content
    return parse_xmldata($xml);
}

# Core XML parsing (internal)
sub parse_xmldata {
    my $text = shift;
    return xml_to_tree($text);
}

# Decode XML entities (internal)
sub decode_entities {
    my $text = shift;
    return '' unless defined $text;
    $text =~ s/&quot;/"/g;
    $text =~ s/&amp;/&/g;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&apos;/'/g;
    # Handle numeric entities (e.g., &#39; for ')
    $text =~ s/&#(\d+);/chr($1)/ge;
    return $text;
}

# Convert XML text to tree structure (internal)
sub xml_to_tree {
    my $text = shift;
    my $tree = {};
    my $curr = $tree;
    my @stack = ();
    my $pos = 0;
    my $len = length($text);

    # Skip XML declaration and DOCTYPE
    $text =~ s/\s*<\?xml(?:[^>]*)>\s*//i;
    $text =~ s/\s*<!DOCTYPE(?:[^>]*)>\s*//i;

    while ( $pos < $len ) {
        my $char = substr($text, $pos, 1);

        # Start of a tag
        if ( $char eq '<' ) {
            if ( substr($text, $pos + 1, 1) eq '/' ) {
                # Closing tag
                my $end = index($text, '>', $pos);
                last if $end == -1;  # Malformed XML
                my $tag = substr($text, $pos + 2, $end - $pos - 2);
                $tag =~ s/\s+$//;  # Trim trailing whitespace
                $pos = $end + 1;

                if ( @stack ) {
                    $curr = pop @stack;  # Move back to parent
                }
            }
            elsif ( substr($text, $pos + 1, 3) eq '!--' ) {
                # Comment
                my $end = index($text, '-->', $pos);
                last if $end == -1;  # Malformed XML
                $pos = $end + 3;  # Skip past comment
            }
            else {
                # Opening or self-closing tag (possibly multi-line)
                my $end = index($text, '>', $pos);
                last if $end == -1;  # Malformed XML
                my $tag_str = substr($text, $pos + 1, $end - $pos - 1);
                $pos = $end + 1;

                # Normalize tag string (remove newlines and extra whitespace)
                $tag_str =~ s/\s+/ /g;  # Collapse whitespace
                $tag_str =~ s/^\s+|\s+$//g;  # Trim leading/trailing whitespace

                my ($tag, %attrs);
                if ( $tag_str =~ /^([^\s\/]+)(.*)$/ ) {
                    $tag = $1;
                    my $attr_str = $2 || '';
                    while ( $attr_str =~ /(\w+)="([^"]*)"/g ) {
                        $attrs{$1} = decode_entities($2);  # Decode entities in attribute values
                    }
                }
                next unless $tag;  # Skip if no tag name

                my $is_self_closing = ($tag_str =~ /\/$/);
                my $node = \%attrs;  # Store attributes in the node

                if ( exists $curr->{$tag} ) {
                    my $existing = $curr->{$tag};
                    if ( ref $existing ne 'ARRAY' ) {
                        $curr->{$tag} = [ $existing ];
                    }
                    push @{ $curr->{$tag} }, $node;
                } else {
                    $curr->{$tag} = $node;
                }

                unless ( $is_self_closing ) {
                    push @stack, $curr;  # Save current node
                    $curr = $node;       # Move to new node
                }
            }
        }
        # Text content
        elsif ( $char ne '>' && $char ne '<' ) {
            my $next_tag = index($text, '<', $pos);
            $next_tag = $len if $next_tag == -1;
            my $text_content = substr($text, $pos, $next_tag - $pos);
            $text_content =~ s/^\s+|\s+$//g;
            if ( $text_content =~ /\S/ ) {
                $curr->{'-text'} = decode_entities($text_content);  # Decode entities in text content
            }
            $pos = $next_tag;
        }
        else {
            $pos++;
        }
    }

    return $tree;
}

sub show_hashformat {
	my ($ph,$format)=@_;
    $format="  %s = %s\n"  if ($format eq '');
	foreach my $key (sort keys %$ph) {
		printf $format,$key,$ph->{$key};
	}
}

sub CMDLINE_parse {
  my ($hash,$sw,$opt)=@_;
  my $nm;

  $sw.=' ';                                 # add trailing space to be sure
  $opt.=' ';
  while (substr($ARGV[0],0,1) eq '-') {
    $nm=substr($ARGV[0],1);
    if ($sw =~ /-$nm / ) {                  # options without params
        if (not exists $hash->{$nm}) {
                $hash->{$nm}=1;
        } else {
                $hash->{$nm}++;             # increase, for -v -v -v
        }
    } elsif ($opt =~ /-$nm / ) {
        $hash->{$nm}=$ARGV[1];
        shift @ARGV;
    } else {
        return(-1);                         # unknown option
    }
    shift @ARGV;
  }
  return(0);
}

sub show_syntax {
    print "Syntax : sln2nmake.pl -pl <x64|win32> -conf <debug|release> \n";
    print "                     [-opts <linker opts>] [-v] <fn.sln> [<vcproj/vcxprojfn>]\n";
    print "         generate a Makefile from a sln file\n";
    print "\n";
	print "Options: -pl      platform, default: $PARAM{pl}\n";
	print "         -conf    config,   default: $PARAM{conf}\n"; 
    print "         -opts    optional linker options\n";
    print "         -v       be more verbose\n";
    exit 1;
}
#EOF
