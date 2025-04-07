#!/usr/bin/perl
use strict;
use warnings;

my $inpfn = $ARGV[0] || '';
if ($inpfn eq '' || ! -f $inpfn) {
    print "Usage: sln2nmake.pl <sln fn> [<vcproj/vcxproj fn>]\n";
    exit 1;
}

my $soldir = $ENV{PWD} || '';
$soldir = qx{pwd} if ($soldir eq '');
$soldir =~ s/[\r\n\s]+$//;
$soldir =~ s|/|\\|g;  # Convert to backslashes
print "soldir = $soldir\n";

my @projects = ();

if (substr($inpfn, -4) eq '.sln') {
    my $proj = $ARGV[1] || '';
    open my $fh, '<', $inpfn or die "Cannot open $inpfn: $!\n";
    while (<$fh>) {
        if (substr($_, 0, 8) eq 'Project(' && $_ =~ /\.(vcproj|vcxproj)/) {
            my (undef, $val) = split(/\s*=\s*/, $_, 2);
            my ($dirnm, $vcfn) = split(/\s*,\s*/, $val);
            $dirnm =~ s/"//g;
            $vcfn =~ s/"//g;
            $vcfn =~ s|/|\\|g;  # Convert to backslashes
            if (-d $dirnm && ($proj eq '' || $dirnm eq $proj)) {
                printf "- ok   %-16s %s\n", $dirnm, $vcfn;
                my $content = read_content($vcfn);
                chdir($dirnm);
                my ($projnm, $nofns, $pafns, $phconf);
                if ($vcfn =~ /\.vcproj$/) {
                    ($projnm, $nofns, $pafns, $phconf) = extract_vcproj($content);
                } elsif ($vcfn =~ /\.vcxproj$/) {
                    ($projnm, $nofns, $pafns, $phconf) = extract_vcxproj($content);
                }
                create_makefile($vcfn, $projnm, $nofns, $pafns, $phconf);
                chdir($soldir);
                push @projects, [$dirnm, $vcfn];
            } else {
                printf "- skip %-16s %s\n", $dirnm, $vcfn;
            }
        } elsif (substr($_, 0, 32) eq 'Microsoft Visual Studio Solution' && $_ =~ /Format Version/i) {
            $_ =~ s/[\r\n\s]+$//;
            my @flds = split(/\s+/, "$_");
            my $version = pop @flds;
            $_ = <$fh>;
            $version .= '  ' . substr($_, 1);
            print "# sln version $version";
        }
    }
    close $fh;
    create_master_makefile($inpfn, \@projects);
} else {
    print "Error: no .sln filename was given\n";
}
exit 0;

sub read_content {
    my $fn = shift;
    open my $fh, '<', $fn or die "Cannot open $fn: $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub extract_vcproj {
    my $content = shift;
    my $project_name = "myprogram";
    if ($content =~ /Name="([^"]+)"/i) { $project_name = $1; }
    my @source_files;
    my %configs;

    while ($content =~ /<File\s+RelativePath="([^"]+\.(cpp|c))"/gi) {
        my $file = $1;
        $file =~ s|/|\\|g;  # Use backslashes
        push @source_files, $file;
    }

    # Support both Release and Debug configurations
    while ($content =~ /<Configuration\s+Name="(Release|Debug)\|([^"]+)"(.*?)<\/Configuration>/gsi) {
        my $config = lc($1);  # release or debug
        my $platform = ($2 =~ /x64/i) ? "x64" : "Win32";
        my $block = $3;
        my @include_dirs = ();
        if ($block =~ /<Tool\s+Name="VCCLCompilerTool".*?AdditionalIncludeDirectories="([^"]*)"/i) {
            @include_dirs = split /;/, $1;
        }
        my @lib_files = ();
        if ($block =~ /<Tool\s+Name="VCLinkerTool".*?AdditionalDependencies="([^"]*)"/i) {
            @lib_files = split /\s+/, $1;
        }
        $configs{"$platform.$config"} = {  # e.g., "Win32.release", "x64.debug"
            include_dirs => \@include_dirs,
            lib_files => \@lib_files,
            output_file => '',
            subsystem => '',
            entry_point => '',
            ignore_libs => [],
        };
    }
    return ($project_name, $#source_files, \@source_files, \%configs);
}

sub extract_vcxproj {
    my $content = shift;
    my $project_name = "myprogram";
    if ($content =~ /<ProjectName>([^<]+)<\/ProjectName>/i) {
        $project_name = $1;
    } elsif ($content =~ /<RootNamespace>([^<]+)<\/RootNamespace>/i) {
        $project_name = $1;
    }
    my @source_files;
    my %configs;

    while ($content =~ /<ClCompile\s+Include="([^"]+\.(cpp|c))"/gi) {
        my $file = $1;
        $file =~ s|/|\\|g;  # Use backslashes
        push @source_files, $file;
    }

    # Support both Release and Debug configurations
    while ($content =~ /<ItemDefinitionGroup\s+Condition="'\$\(Configuration\)\|\$\(Platform\)'=='(Release|Debug)\|([^']+)'"(.*?)<\/ItemDefinitionGroup>/gsi) {
        my $config = lc($1);  # release or debug
        my $platform = ($2 =~ /x64/i) ? "x64" : "Win32";
        my $block = $3;

        my @include_dirs = ();
        if ($block =~ /<AdditionalIncludeDirectories>([^<]+)<\/AdditionalIncludeDirectories>/i) {
            @include_dirs = split /;/, $1;
            @include_dirs = grep { $_ !~ /^\s*$/ && $_ !~ /\$\(/ } @include_dirs;
        }

        my @lib_files = ();
        my $output_file = '';
        my $subsystem = '';
        my $entry_point = '';
        my @ignore_libs = ();

        if ($block =~ /<Link>(.*?)<\/Link>/si) {
            my $link_block = $1;
            if ($link_block =~ /<AdditionalDependencies>([^<]+)<\/AdditionalDependencies>/i) {
                @lib_files = split /;/, $1;
                @lib_files = grep { $_ !~ /^\s*$/ && $_ !~ /%/ } @lib_files;
            }
            if ($link_block =~ /<OutputFile>([^<]+)<\/OutputFile>/i) {
                $output_file = $1;
                $output_file =~ s|/|\\|g;  # Use backslashes
            }
            if ($link_block =~ /<SubSystem>([^<]+)<\/SubSystem>/i) {
                $subsystem = $1;
            }
            if ($link_block =~ /<EntryPointSymbol>([^<]+)<\/EntryPointSymbol>/i) {
                $entry_point = $1;
            }
            if ($link_block =~ /<IgnoreSpecificDefaultLibraries>([^<]+)<\/IgnoreSpecificDefaultLibraries>/i) {
                @ignore_libs = split /;/, $1;
                @ignore_libs = grep { $_ !~ /^\s*$/ && $_ !~ /%/ } @ignore_libs;
            }
        }

        $configs{"$platform.$config"} = {  # e.g., "Win32.release", "x64.debug"
            include_dirs => \@include_dirs,
            lib_files => \@lib_files,
            output_file => $output_file,
            subsystem => $subsystem,
            entry_point => $entry_point,
            ignore_libs => \@ignore_libs,
        };
    }

    return ($project_name, $#source_files, \@source_files, \%configs);
}

sub create_makefile {
    my ($projfn, $projnm, $nofns, $pafns, $phconf) = @_;
    my @obj_files = map { my $f = $_; $f =~ s/\.(cpp|c)$/\.obj/i; $f =~ s|^.*[\\\/]||; $f } @$pafns;

    open my $makefile, '>', 'Makefile' or die "Cannot write Makefile: $!\n";
    print $makefile "# NMAKE Makefile generated from $projfn\n\n";
    print $makefile "SOLDIR = $soldir\n";
    print $makefile "CC = cl\n";
    print $makefile "LINK = link\n\n";

    foreach my $platform ("Win32", "x64") {
        foreach my $config ("release", "debug") {
            my $key = "$platform.$config";
            next unless exists $phconf->{$key};
            my $cfg = $phconf->{$key};
            my $out_dir = ($platform eq "x64") ? "x64\\$config" : "$config";
            my $exe_name = $cfg->{output_file} || "$out_dir\\$projnm.exe";

            print $makefile "# $platform " . ucfirst($config) . " Configuration\n";
            print $makefile "CFLAGS_$platform" . "_$config = /EHsc " . ($config eq "release" ? "/MT" : "/MTd");  # MT for Release, MTd for Debug
            print $makefile " /I" . join(" /I", @{$cfg->{include_dirs}}) if $cfg->{include_dirs} && @{$cfg->{include_dirs}};
            print $makefile "\n";
            print $makefile "LFLAGS_$platform" . "_$config =";
            print $makefile " " . join(" ", @{$cfg->{lib_files}}) if $cfg->{lib_files} && @{$cfg->{lib_files}};
            print $makefile " /SUBSYSTEM:$cfg->{subsystem}" if $cfg->{subsystem};
            print $makefile " /ENTRY:$cfg->{entry_point}" if $cfg->{entry_point};
            print $makefile " /NODEFAULTLIB:" . join(" /NODEFAULTLIB:", @{$cfg->{ignore_libs}}) if $cfg->{ignore_libs} && @{$cfg->{ignore_libs}};
            print $makefile "\n\n";

            print $makefile "$platform$config: $exe_name\n\n";
            print $makefile "$exe_name: $out_dir @obj_files\n";
            print $makefile "\t\$(LINK) /OUT:$exe_name \$(LFLAGS_$platform" . "_$config) @obj_files\n\n";

            foreach my $i (0 .. $nofns) {
                my $obj_out = "$out_dir\\$obj_files[$i]";
                print $makefile "$obj_out: $pafns->[$i]\n";
                print $makefile "\tIF NOT EXIST $out_dir mkdir $out_dir\n";
                print $makefile "\t\$(CC) /c \$(CFLAGS_$platform" . "_$config) /Fo$obj_out $pafns->[$i]\n\n";
            }
        }
    }

    print $makefile "all: Win32release Win32debug x64release x64debug\n\n";
    print $makefile "clean:\n";
    print $makefile "\tdel Release\\*.obj Debug\\*.obj x64\\Release\\*.obj x64\\Debug\\*.obj $projnm.exe\n";
    print $makefile "\trmdir /S /Q Release Debug x64\n";
    close $makefile;
    print "  Generated Makefile\n";
}

sub create_master_makefile {
    my ($slnfn, $projects_ref) = @_;
    my @projects = @$projects_ref;

    open my $master, '>', 'Makefile' or die "Cannot write master Makefile: $!\n";
    print $master "# Master NMAKE Makefile generated from $slnfn\n\n";
    print $master "SOLDIR = $soldir\n\n";

    my @project_targets = map { $_->[0] } @projects;
    print $master "all: @project_targets\n\n";

    for my $proj (@projects) {
        my ($dirnm, $vcfn) = @$proj;
        print $master "$dirnm:\n";
        print $master "\tcd $dirnm && nmake -f Makefile all\n";
        print $master "\tcd \$(SOLDIR)\n\n";
    }

    print $master "clean:\n";
    for my $proj (@projects) {
        my ($dirnm, $vcfn) = @$proj;
        print $master "\tcd $dirnm && nmake -f Makefile clean\n";
        print $master "\tcd \$(SOLDIR)\n";
    }
    print $master "\tdel *.exe 2>NUL\n";

    close $master;
    print "Generated master Makefile in $soldir\n";
}

#EOF