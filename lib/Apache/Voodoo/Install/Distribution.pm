=pod ###########################################################################

=head1 NAME

Apache::Voodoo::Install::Updater

=head1 VERSION

$Id: Distribution.pm 4342 2006-12-18 23:21:06Z medwards $

=head1 SYNOPSIS

This package provides the methods that do pre/post/upgrade commands as specified
by the various .xml files in an application.

=cut ###########################################################################
package Apache::Voodoo::Install::Distribution;

$VERSION = '1.21';

use strict;
use warnings;

use base("Apache::Voodoo::Install");

use Apache::Voodoo::Constants;

use File::Spec;
use Config::General;
use ExtUtils::Install;

sub new {
	my $class = shift;
	my %params = @_;

	my $self = {%params};

	$self->{'distribution'} = File::Spec->rel2abs($self->{'distribution'});

	unless (-e $self->{'distribution'} && -f $self->{'distribution'}) {
		die "ERROR: No such file or directory\n";
	}

	$self->{'app_name'} = $self->{'distribution'};
	$self->{'app_name'} =~ s/\.tar\.(bz2|gz)$//i;
	$self->{'app_name'} =~ s/-.*$//;
	$self->{'app_name'} =~ s/.*\///;

	unless ($self->{'app_name'} =~ /^[a-z]\w*$/i) {
		die "ERROR: Distribution file names must follow the format: AppName-Version.tar.(gz|bz2)\n";
	}

	my $ac = Apache::Voodoo::Constants->new();
	$self->{'ac'} = $ac;

	$self->{'install_path'} = $ac->install_path()."/".$self->{'app_name'};

	$self->{'conf_file'}    = $self->{'install_path'}."/".$ac->conf_file();
	$self->{'conf_path'}    = $self->{'install_path'}."/".$ac->conf_path();
	$self->{'updates_path'} = $self->{'install_path'}."/".$ac->updates_path();
	$self->{'apache_uid'}   = $ac->apache_uid();
	$self->{'apache_gid'}   = $ac->apache_gid();

	bless $self,$class;

	return $self;
}

sub app_name {
	my $self = shift;
	$self->{'app_name'} = $_[0] if $_[0];
	return $self->{'app_name'};
}

sub existing {
	my $self = shift;
	return $self->{'is_existing'};
}

################################################################################
# Handles installer cleanup tasks.
################################################################################
sub DESTROY {
	my $self = shift;

	if ($self->{'unpack_dir'}) {
		system("rm", "-rf", $self->{'unpack_dir'});
	}
}

sub do_install {
	my $self = shift;

	$self->unpack_distribution();
	$self->check_existing();
	$self->update_conf_file();
	$self->install_files();
}

################################################################################
# Unpacks a tar.gz to a temporary directory.
# Returns the path to the directory.
################################################################################
sub unpack_distribution {
	my $self = shift;

	my $file = $self->{'distribution'};

	my $unpack_dir = "/tmp/av_unpack_$$";

	if (-e $unpack_dir) {
		die "ERROR: $unpack_dir already exists\n";
	}

	mkdir($unpack_dir,0700) || die "Can't create directory $unpack_dir: $!";
	chdir($unpack_dir) || die "Can't change to direcotyr $unpack_dir: $!";
	$self->info("- Unpacking distribution to $unpack_dir");

	if ($file =~ /\.gz$/) {
		system("tar","xzf",$file) && die "Can't unpack $file: $!";
	}
	else {
		system("tar","xjf",$file) && die "Can't unpack $file: $!";
	}

	$self->{'unpack_dir'} = $unpack_dir;

	my $new_conf = $self->{'unpack_dir'}."/".$self->{'ac'}->conf_file();

	unless (-e $new_conf) {
		print "ERROR: install doesn't contain a configuration file at: $new_conf\n";
		exit;
	}
}

################################################################################
# Checks for an existing installation of the app.  If it exists, it saves
# it's site specific config data, and returns it's version number.
################################################################################
sub check_existing {
	my $self = shift;

	my $conf_file = $self->{'conf_file'};

	if (-e $conf_file) {
		$self->{'is_existing'} = 1;
		$self->info("Found one. We will be performing an upgrade");

		my $old_config = Config::General->new($conf_file);
		my %old_cdata = $old_config->getall();

		# save old (maybe customized?) config variables
		foreach ('session_dir','devel_mode','shared_cache','ipc_max_size', 'debug','devel_mode','cookie_name','database') {
			$self->{'old_conf_data'}->{$_} = $old_cdata{$_};
		}

		my $dbhost = $old_cdata{'database'}->{'connect'};
		my $dbname = $old_cdata{'database'}->{'connect'};

		$dbhost =~ s/.*\bhost=//;
		$dbhost =~ s/[^\w\.-]+.*$//;

		$dbname =~ s/.*\bdatabase=//;
		$dbname =~ s/[^\w\.-]+.*$//;

		$self->{'dbhost'} ||= $dbhost;
		$self->{'dbname'} ||= $dbname;
		$self->{'dbuser'} ||= $old_cdata{'database'}->{'username'};
		$self->{'dbpass'} ||= $old_cdata{'database'}->{'password'};
	}
	else {
		$self->info("not found. This will be a fresh install.");
	}
}

sub update_conf_file {
	my $self = shift;

	my $new_conf = $self->{'unpack_dir'}."/".$self->{'ac'}->conf_file();

	my $config = Config::General->new($new_conf);
	my %cdata = $config->getall();

	foreach (keys %{$self->{'old_conf_data'}}) {
		$self->debug("Merging config data: $_");
		$cdata{$_} = $self->{'old_conf_data'}->{$_};
	}

	$self->debug("Merging database config");
	$cdata{'database'}->{'username'} = $self->{'dbuser'}                               if $self->{'dbuser'};
	$cdata{'database'}->{'password'} = $self->{'dbpass'}                               if $self->{'dbpass'};
	$cdata{'database'}->{'connect'} =~ s/\bdatabase=[^;"]+/database=$self->{'dbname'}/ if $self->{'dbname'};
	$cdata{'database'}->{'connect'} =~ s/\bhost=[^;"]+/host=$self->{'dbhost'}/         if $self->{'dbhost'};

	$self->{'pretend'} || $config->save_file($new_conf,\%cdata);
}

sub install_files {
	my $self = shift;

	my $unpack_dir   = $self->{'unpack_dir'};
	my $install_path = $self->{'install_path'};

	if ($self->{'verbose'} >= 0) {
		$self->mesg("\n* Preparing to install.  Press ctrl-c to abort *\n");
		$self->mesg("* Installing in ");
		foreach (5,4,3,2,1) {
			$self->mesg("$_");
			$self->{'pretend'} || sleep(1);
		}
		$self->mesg("\n");

		$self->mesg("- Installing files:");
	}

	$self->{'pretend'} || ExtUtils::Install::install({$unpack_dir => $install_path});
}

1;

=pod ################################################################################

=head1 AUTHOR

Maverick, /\/\averick@smurfbaneDOTorg

=head1 COPYRIGHT

Copyright (c) 2005 Steven Edwards.  All rights reserved.

You may use and distribute Voodoo under the terms described in the LICENSE file include
in this package or L<Apache::Voodoo::license>.  The summary is it's a legalese version
of the Artistic License :)

=cut ################################################################################
