#!/usr/bin/perl
#
# setup-openssh.pl
#
# Adapts the installed gsi-openssh environment to the current machine,
# performing actions that originally occurred during the package's
# 'make install' phase.
#
# Send comments/fixes/suggestions to:
# Chase Phillips <cphillip@ncsa.uiuc.edu>
#

printf("setup-openssh.pl: Configuring gsi-openssh package\n");

#
# Get user's GPT_LOCATION since we may be installing this using a new(er)
# version of GPT.
#

$gptpath = $ENV{GPT_LOCATION};

#
# And the old standby..
#

$gpath = $ENV{GLOBUS_LOCATION};
if (!defined($gpath))
{
    die "GLOBUS_LOCATION needs to be set before running this script"
}

#
# modify the ld library path for when we call ssh executables
#

$oldldpath = $ENV{LD_LIBRARY_PATH};
$newldpath = "$gpath/lib";
if (length($oldldpath) > 0)
{
    $newldpath .= ":$oldldpath";
}
$ENV{LD_LIBRARY_PATH} = "$newldpath";

#
# i'm including this because other perl scripts in the gpt setup directories
# do so
#

if (defined($gptpath))
{
    @INC = (@INC, "$gptpath/lib/perl", "$gpath/lib/perl");
}
else
{
    @INC = (@INC, "$gpath/lib/perl");
}

require Grid::GPT::Setup;

my $globusdir = $gpath;
my $myname = "setup-openssh.pl";

#
# Set up path prefixes for use in the path translations
#

$prefix = ${globusdir};
$exec_prefix = "${prefix}";
$bindir = "${exec_prefix}/bin";
$sbindir = "${exec_prefix}/sbin";
$sysconfdir = "$prefix/etc/ssh";
$localsshdir = "/etc/ssh";
$setupdir = "$prefix/setup/gsi_openssh_setup";

my $keyfiles = {
                 "dsa" => "ssh_host_dsa_key",
                 "rsa" => "ssh_host_rsa_key",
                 "rsa1" => "ssh_host_key",
               };

sub copyKeyFiles
{
    my($copylist) = @_;
    my($regex, $basename);

    if (@$copylist)
    {
        print "Copying ssh host keys...\n";

        for my $f (@$copylist)
        {
            $f =~ s:/+:/:g;

            if (length($f) > 0)
            {
                $keyfile = "$f";
                $pubkeyfile = "$f.pub";

                action("cp $localsshdir/$keyfile $sysconfdir/$keyfile");
                action("cp $localsshdir/$pubkeyfile $sysconfdir/$pubkeyfile");
            }
        }
    }
}

sub isReadable
{
    my($file) = @_;

    if ( ( -e $file ) && ( -r $file ) )
    {
        return 1;
    }
    else
    {
        return 0;
    }
}

sub isPresent
{
    my($file) = @_;

    if ( -e $file )
    {
        return 1;
    }
    else
    {
        return 0;
    }
}

sub determineKeys
{
    my($keyhash, $keylist);
    my($count);

    #
    # initialize our variables
    #

    $count = 0;

    $keyhash = {};
    $keyhash->{gen} = [];   # a list of keytypes to generate
    $keyhash->{copy} = [];  # a list of files to copy from the 

    $genlist = $keyhash->{gen};
    $copylist = $keyhash->{copy};

    #
    # loop over our keytypes and determine what we need to do for each of them
    #

    for my $keytype (keys %$keyfiles)
    {
        $basekeyfile = $keyfiles->{$keytype};

        #
        # if the key's are already present, we don't need to bother with this rigamarole
        #

        $gkeyfile = "$sysconfdir/$basekeyfile";
        $gpubkeyfile = "$sysconfdir/$basekeyfile.pub";

        if ( isPresent($gkeyfile) && isPresent($gpubkeyfile) )
        {
            next;
        }

        #
        # if we can find a copy of the keys in /etc/ssh, we'll copy them to the user's
        # globus location
        #

        $mainkeyfile = "$localsshdir/$basekeyfile";
        $mainpubkeyfile = "$localsshdir/$basekeyfile.pub";

        if ( isReadable($mainkeyfile) && isReadable($mainpubkeyfile) )
        {
            push(@$copylist, $basekeyfile);
            $count++;
            next;
        }

        #
        # otherwise, we need to generate the key
        #

        push(@$genlist, $keytype);
        $count++;
    }

    if ($count > 0)
    {
        if ( ! -d $sysconfdir )
        {
            print "Could not find ${sysconfdir} directory... creating\n";
            action("mkdir -p $sysconfdir");
        }
    }

    return $keyhash;
}

sub runKeyGen
{
    my($gen_keys) = @_;
    my $keygen = "$bindir/ssh-keygen";

    if (@$gen_keys && -x $keygen)
    {
        print "Generating ssh host keys...\n";

        for my $k (@$gen_keys)
        {
            $keyfile = $keyfiles->{$k};

            # if $sysconfdir/$keyfile doesn't exist..
            action("$bindir/ssh-keygen -t $k -f $sysconfdir/$keyfile -N \"\"");
        }
    }

    return 0;
}

sub fixpaths
{
    my $g, $h;

    print "Fixing sftp-server path in sshd_config...\n";

    $f = "$gpath/etc/ssh/sshd_config";
    $g = "$f.tmp";

    if ( ! -f "$f" )
    {
        printf("Cannot find $f!");
        return;
    }

    #
    # Grab the current mode/uid/gid for use later
    #

    $mode = (stat($f))[2];
    $uid = (stat($f))[4];
    $gid = (stat($f))[5];

    #
    # Move $f into a .tmp file for the translation step
    #

    $result = system("mv $f $g 2>&1");
    if ($result or $?)
    {
        die "ERROR: Unable to execute command: $!\n";
    }

    open(IN, "<$g") || die ("$0: input file $g missing!\n");
    open(OUT, ">$f") || die ("$0: unable to open output file $f!\n");

    while (<IN>)
    {
        #
        # sorry for the whacky regex, but i need to verify a whole line
        #

        if ( /^\s*Subsystem\s+sftp\s+\S+\s*$/ )
        {
            $_ = "Subsystem\tsftp\t$gpath/libexec/sftp-server\n";
            $_ =~ s:/+:/:g;
        }
        print OUT "$_";
    } # while <IN>

    close(OUT);
    close(IN);

    #
    # Remove the old .tmp file
    #

    $result = system("rm $g 2>&1");

    if ($result or $?)
    {
        die "ERROR: Unable to execute command: $!\n";
    }

    #
    # An attempt to revert the new file back to the original file's
    # mode/uid/gid
    #

    chmod($mode, $f);
    chown($uid, $gid, $f);

    return 0;
}

sub alterFileGlobusLocation
{
    my ($in, $out) = @_;

    if ( -r $in )
    {
        if ( ( -w $out ) || ( ! -e $out ) )
        {
            $data = readFile($in);
            $data =~ s|\@GLOBUS_LOCATION\@|$gpath|g;
            writeFile($out, $data);
            action("chmod 755 $out");
        }
    }
}

sub alterFiles
{
    alterFileGlobusLocation("$setupdir/SXXsshd.in", "$sbindir/SXXsshd");
}

### readFile( $filename )
#
# reads and returns $filename's contents
#

sub readFile
{
    my ($filename) = @_;
    my $data;

    open (IN, "$filename") || die "Can't open '$filename': $!";
    $/ = undef;
    $data = <IN>;
    $/ = "\n";
    close(IN);

    return $data;
}

### writeFile( $filename, $fileinput )
#
# create the inputs to the ssl program at $filename, appending the common name to the
# stream in the process
#

sub writeFile
{
    my ($filename, $fileinput) = @_;

    #
    # test for a valid $filename
    #

    if ( !defined($filename) || (length($filename) lt 1) )
    {
        die "Filename is undefined";
    }

    if ( ( -e "$filename" ) && ( ! -w "$filename" ) )
    {
        die "Cannot write to filename '$filename'";
    }

    #
    # write the output to $filename
    #

    open(OUT, ">$filename");
    print OUT "$fileinput";
    close(OUT);
}

print "---------------------------------------------------------------------\n";
print "Hi, I'm the setup script for the gsi_openssh package!  There\n";
print "are some last minute details that I've got to set straight\n";
print "in the sshd config file, along with generating the ssh keys\n";
print "for this machine (if it doesn't already have them).\n";
print "\n";
print "If I find a pair of host keys in /etc/ssh, I will copy them into\n";
print "\$GLOBUS_LOCATION/etc/ssh.  If they aren't present, I will generate\n";
print "them for you.\n";
print "\n";

$response = query_boolean("Do you wish to continue with the setup package?","y");
if ($response eq "n")
{
    print "\n";
    print "Okay.. exiting gsi_openssh setup.\n";

    exit 0;
}

print "\n";

$keyhash = determineKeys();
runKeyGen($keyhash->{gen});
copyKeyFiles($keyhash->{copy});
fixpaths();
alterFiles();

my $metadata = new Grid::GPT::Setup(package_name => "gsi_openssh_setup");

$metadata->finish();

print "\n";
print "Additional Notes:\n";
print "\n";
print "  o I see that you have your GLOBUS_LOCATION environmental variable\n";
print "    set to:\n";
print "\n";
print "    \t\"$gpath\"\n";
print "\n";
print "    Remember to keep this variable set (correctly) when you want to\n";
print "    use the executables that came with this package.\n";
print "\n";
print "  o You may need to set LD_LIBRARY_PATH to point to the location in\n";
print "    which your globus libraries reside.  For example:\n";
print "\n";
print "    \t\$ LD_LIBRARY_PATH=\"$gpath/lib:\$LD_LIBRARY_PATH\"; \\\n";
print "    \t     export LD_LIBRARY_PATH\n";
print "\n";
print "    If you wish, you may run, e.g.:\n";
print "\n";
print "    \t\$ . \$GLOBUS_LOCATION/etc/globus-user-env.sh\n";
print "\n";
print "    to prepare your environment for running the gsi_openssh\n";
print "    executables.\n";
print "\n";
print "---------------------------------------------------------------------\n";
print "$myname: Finished configuring package 'gsi_openssh'.\n";

#
# Just need a minimal action() subroutine for now..
#

sub action
{
    my ($command) = @_;

    printf "$command\n";

    my $result = system("LD_LIBRARY_PATH=\"$gpath/lib:\$LD_LIBRARY_PATH\"; $command 2>&1");

    if (($result or $?) and $command !~ m!patch!)
    {
        die "ERROR: Unable to execute command: $!\n";
    }
}

sub query_boolean
{
    my ($query_text, $default) = @_;
    my $nondefault, $foo, $bar;

    #
    # Set $nondefault to the boolean opposite of $default.
    #

    if ($default eq "n")
    {
        $nondefault = "y";
    }
    else
    {
        $nondefault = "n";
    }

    print "${query_text} ";
    print "[$default] ";

    $foo = <STDIN>;
    ($bar) = split //, $foo;

    if ( grep(/\s/, $bar) )
    {
        # this is debatable.  all whitespace means 'default'

        $bar = $default;
    }
    elsif ($bar ne $default)
    {
        # everything else means 'nondefault'.

        $bar = $nondefault;
    }
    else
    {
        # extraneous step.  to get here, $bar should be eq to $default anyway.

        $bar = $default;
    }

    return $bar;
}
