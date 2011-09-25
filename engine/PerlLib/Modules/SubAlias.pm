#!/usr/bin/perl

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010 - 2011 by internet Multi Server Control Panel
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# @category		i-MSCP
# @copyright	2010 - 2011 by i-MSCP | http://i-mscp.net
# @author		Daniel Andreca <sci2tech@gmail.com>
# @version		SVN: $Id$
# @link			http://i-mscp.net i-MSCP Home Site
# @license		http://www.gnu.org/licenses/gpl-2.0.html GPL v2

package Modules::SubAlias;

use strict;
use warnings;
use iMSCP::Debug;
use Data::Dumper;

use vars qw/@ISA/;

@ISA = ('Common::SimpleClass', 'Modules::Subdomain');
use Common::SimpleClass;
use Modules::Subdomain;

sub _init{
	my $self		= shift;
	$self->{type}	= 'Sub';
}

sub loadData{
	debug('Starting...');

	my $self = shift;

	my $sql = "
		SELECT
			`sub`.*,
			`domain_name` AS `user_home`,
			`alias_name`,
			`domain_admin_id`,
			`domain_php`,
			`domain_cgi`,
			`domain_traffic_limit`,
			`domain_mailacc_limit`,
			`domain_dns`,
			`domain`.`domain_id`,
			`ips`.`ip_number`,
			`mail_count`.`mail_on_domain`
		FROM
			`subdomain_alias` AS `sub`
		LEFT JOIN
			`domain_aliasses` as `alias`
		ON
			`sub`.`alias_id` = `alias`.`alias_id`
		LEFT JOIN
			`domain`
		ON
			`alias`.`domain_id` = `domain`.`domain_id`
		LEFT JOIN
			`server_ips` AS `ips`
		ON
			`alias`.`alias_ip_id` = `ips`.`ip_id`
		LEFT JOIN
			(SELECT `sub_id` AS `id`, COUNT( `sub_id` ) AS `mail_on_domain` FROM `mail_users` WHERE `sub_id`= ? AND `mail_type` IN ('alssub_mail', 'alssub_forward', 'alssub_mail,alssub_forward', 'alssub_catchall') GROUP BY `sub_id`) AS `mail_count`
		ON
			`sub`.`subdomain_alias_id` = `mail_count`.`id`
		WHERE
			`sub`.`subdomain_alias_id` = ?
	";

	my $rdata = iMSCP::Database->factory()->doQuery('subdomain_alias_id', $sql, $self->{subId}, $self->{subId});

	error("$rdata") and return 1 if(ref $rdata ne 'HASH');
	error("No alias subdomain has id = $self->{subId}") and return 1 unless(exists $rdata->{$self->{subId}});

	$self->{$_} = $rdata->{$self->{subId}}->{$_} for keys %{$rdata->{$self->{subId}}};

	debug('Ending...');
	0;
}

sub process{
	debug('Starting...');

	my $self		= shift;
	$self->{subId}	= shift;

	my $rs = $self->loadData();
	return $rs if $rs;

	my @sql;

	if($self->{subdomain_alias_status} =~ /^toadd|change|toenable|dnschange$/){
		$rs = $self->add();
		@sql = (
			"UPDATE `subdomain_alias` SET `subdomain_alias_status` = ? WHERE `subdomain_alias_id` = ?",
			($rs ? scalar getMessageByType('ERROR') : 'ok'),
			$self->{subdomain_alias_id}
		);
	}elsif($self->{subdomain_alias_status} =~ /^delete$/){
		$rs = $self->delete();
		if($rs){
			@sql = (
				"UPDATE `subdomain_alias` SET `subdomain_alias_status` = ? WHERE `subdomain_alias_id` = ?",
				scalar getMessageByType('ERROR'),
				$self->{subdomain_alias_id}
			);
		}else {
			@sql = ("DELETE FROM `subdomain_alias` WHERE `subdomain_alias_id` = ?", $self->{subdomain_alias_id});
		}
	}elsif($self->{subdomain_alias_status} =~ /^todisable$/){
		$rs = $self->disable();
		@sql = (
			"UPDATE `subdomain_alias` SET `subdomain_alias_status` = ? WHERE `subdomain_alias_id` = ?",
			($rs ? scalar getMessageByType('ERROR') : 'disabled'),
			$self->{subdomain_alias_id}
		);
	}elsif($self->{subdomain_alias_status} =~ /^restore$/){
		$rs = $self->restore();
		@sql = (
			"UPDATE `subdomain_alias` SET `subdomain_alias_status` = ? WHERE `subdomain_alias_id` = ?",
			($rs ? scalar getMessageByType('ERROR') : 'ok'),
			$self->{subdomain_alias_id}
		);
	}

	my $rdata = iMSCP::Database->factory()->doQuery('delete', @sql);
	error("$rdata") and return 1 if(ref $rdata ne 'HASH');

	debug('Ending...');
	$rs;
}

sub delete{
	debug('Starting...');

	use File::Temp;
	use iMSCP::Database;
	use iMSCP::Servers;
	use iMSCP::Addons;
	use iMSCP::Execute;
	use iMSCP::Dir;

	my $self		= shift;
	my $rs = 0;
	my ($stdout, $stderr);

	my @sql = ("
		SELECT `alias_mount` AS `mount_point`, concat('alias',`alias_id`) AS 'id'
		FROM `domain_aliasses`
		WHERE `alias_mount` LIKE '$self->{subdomain_alias_mount}%'
		AND `alias_status` NOT IN ('delete', 'ordered')
		AND `domain_id` = ?
		UNION
		SELECT `subdomain_mount` AS `mount_point`, concat('subdomain',`subdomain_id`) as 'id'
		FROM `subdomain`
		WHERE `subdomain_mount` LIKE '$self->{subdomain_alias_mount}%'
		AND `subdomain_status` != 'delete'
		AND `domain_id` = ?
		UNION
		SELECT `subdomain_alias_mount` AS `mount_point`, concat('subdomain_alias',`subdomain_alias_id`) as 'id'
		FROM `subdomain_alias`
		WHERE `subdomain_alias_mount` LIKE '$self->{subdomain_alias_mount}%'
		AND `subdomain_alias_status` != 'delete'
		AND `alias_id` IN (SELECT `alias_id` FROM `domain_aliasses` WHERE `domain_id` = ?)
		",
		$self->{domain_id},
		$self->{domain_id},
		$self->{domain_id}
	);

	my $rdata = iMSCP::Database->factory()->doQuery('id', @sql);
	error("$rdata") and return 1 if(ref $rdata ne 'HASH');

	my %mountPoints;
	unless($self->{subdomain_alias_mount} eq '/'){
		my %toSaveMountPoints;
		%mountPoints = map{$_ => $rdata->{$_}->{mount_point}} keys%{$rdata};

		foreach(keys %mountPoints){
			my $mp = $rdata->{$_}->{mount_point};
			my $id = $_;
			if(grep $mp =~ m/^$rdata->{$_}->{mount_point}/ && $id ne $_, keys %mountPoints){
				delete $mountPoints{$id};
			}
		}
	} else {
		$mountPoints{'1'} = '/';
	}


	my $dir = File::Temp->newdir(CLEANUP => 1);
	my @savedDirs;
	foreach(keys %mountPoints){
		my $sourceDir 	= "$main::imscpConfig{'USER_HOME_DIR'}/$self->{user_home}/".$mountPoints{$_};
		$sourceDir		=~ s~/+~/~g;
		my $destDir 	= "$dir/".$mountPoints{$_};
		$destDir		=~ s~/+~/~g;
		$rs |= iMSCP::Dir->new(dirname => "$destDir")->make();
		$rs |= execute("mv -Tfv $sourceDir $destDir", \$stdout, \$stderr);
		debug("$stdout") if $stdout;
		error("$stderr") if $stderr;
		return $rs if $rs;
		push(@savedDirs, $mountPoints{$_});
	}

	$self->{mode}	= 'del';
	$rs 			= $self->runAllSteps();

	foreach (@savedDirs){
		my $destDir 	= "$main::imscpConfig{'USER_HOME_DIR'}/$self->{user_home}/$_";
		$destDir		=~ s~/+~/~g;
		my $sourceDir	= "$dir/$_";
		$sourceDir		=~ s~/+~/~g;
		$rs |= iMSCP::Dir->new(dirname => "$destDir")->make();
		$rs |= execute("mv -Tfv $sourceDir $destDir ", \$stdout, \$stderr);
		debug("$stdout") if $stdout;
		error("$stderr") if $stderr;
		return $rs if $rs;
	}

	debug('Ending...');
	$rs;
}

sub buildHTTPDData{
	debug('Starting...');

	my $self	= shift;
	my $groupName	=
	my $userName	=
			$main::imscpConfig{SYSTEM_USER_PREFIX}.
			($main::imscpConfig{SYSTEM_USER_MIN_UID} + $self->{domain_admin_id});
	my $hDir 		= "$main::imscpConfig{'USER_HOME_DIR'}/$self->{user_home}/$self->{subdomain_alias_mount}";
	$hDir			=~ s~/+~/~g;

	my $sql = "SELECT * FROM `config` WHERE `name` LIKE 'PHPINI%'";
	my $rdata = iMSCP::Database->factory()->doQuery('name', $sql);
	error("$rdata") and return 1 if(ref $rdata ne 'HASH');

	$sql			= "SELECT * FROM `php_ini` WHERE `domain_id` = ?";
	my $phpiniData	= iMSCP::Database->factory()->doQuery('domain_id', $sql, $self->{domain_id});
	error("$rdata") and return 1 if(ref $rdata ne 'HASH');

	$self->{httpd} = {
		DMN_NAME					=> $self->{subdomain_alias_name}.'.'.$self->{alias_name},
		ROOT_DMN_NAME				=> $self->{user_home},
		PARENT_DMN_NAME				=> $self->{alias_name},
		DMN_IP						=> $self->{ip_number},
		WWW_DIR						=> $main::imscpConfig{'USER_HOME_DIR'},
		HOME_DIR					=> $hDir,
		PEAR_DIR					=> $main::imscpConfig{'PEAR_DIR'},
		PHP_TIMEZONE				=> $main::imscpConfig{'PHP_TIMEZONE'},
		PHP_VERSION					=> $main::imscpConfig{'PHP_VERSION'},
		BASE_SERVER_VHOST_PREFIX	=> $main::imscpConfig{'BASE_SERVER_VHOST_PREFIX'},
		BASE_SERVER_VHOST			=> $main::imscpConfig{'BASE_SERVER_VHOST'},
		USER						=> $userName,
		GROUP						=> $groupName,
		have_php					=> $self->{domain_php},
		have_cgi					=> $self->{domain_cgi},
		BWLIMIT						=> $self->{domain_traffic_limit},
		ALIAS						=> $userName.'subals'.$self->{subdomain_alias_id},
		FORWARD						=> $self->{subdomain_alias_url_forward},
		DISABLE_FUNCTIONS			=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{disable_functions} : $rdata->{PHPINI_DISABLE_FUNCTIONS}->{value}),
		MAX_EXECUTION_TIME			=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{max_execution_time} : $rdata->{PHPINI_MAX_EXECUTION_TIME}->{value}),
		MAX_INPUT_TIME				=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{max_input_time} : $rdata->{PHPINI_MAX_INPUT_TIME}->{value}),
		MEMORY_LIMIT				=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{memory_limit} : $rdata->{PHPINI_MEMORY_LIMIT}->{value}),
		ERROR_REPORTING				=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{error_reporting} : $rdata->{PHPINI_ERROR_REPORTING}->{value}),
		DISPLAY_ERRORS				=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{display_errors} : $rdata->{PHPINI_DISPLAY_ERRORS}->{value}),
		REGISTER_GLOBALS			=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{register_globals} : $rdata->{PHPINI_REGISTER_GLOBALS}->{value}),
		POST_MAX_SIZE				=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{post_max_size} : $rdata->{PHPINI_POST_MAX_SIZE}->{value}),
		UPLOAD_MAX_FILESIZE			=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{upload_max_filesize} : $rdata->{PHPINI_UPLOAD_MAX_FILESIZE}->{value}),
		ALLOW_URL_FOPEN				=> (exists $phpiniData->{$self->{domain_id}} ? $phpiniData->{$self->{domain_id}}->{allow_url_fopen} : $rdata->{PHPINI_ALLOW_URL_FOPEN}->{value})
	};

	debug('Ending...');
	0;
}

sub buildMTAData{
	debug('Starting...');

	my $self	= shift;

	if(
		$self->{mode} ne 'add'
		||
		defined $self->{mail_on_domain} && $self->{mail_on_domain} > 0
		||
		defined $self->{domain_mailacc_limit} && $self->{domain_mailacc_limit} >=0
	){
		$self->{mta} = {
			DMN_NAME	=> $self->{subdomain_alias_name}.'.'.$self->{alias_name},
			TYPE		=> 'valssub_entry'
		};
	}

	debug('Ending...');
	0;
}

sub buildNAMEDData{
	debug('Starting...');

	my $self	= shift;

	$self->{named} = {
		DMN_NAME		=> $self->{subdomain_alias_name}.'.'.$self->{alias_name},
		PARENT_DMN_NAME	=> $self->{alias_name},
		DMN_IP			=> $self->{ip_number}
	};

	debug('Ending...');
	0;
}

sub buildFTPDData{
	debug('Starting...');

	my $self	= shift;
	my $rs 		= 0;
	my ($stdout, $stderr);
	my $file_name	= "$self->{subdomain_alias_name}.$self->{alias_name}.$self->{subdomain_alias_mount}";
	my $hDir 		= "$main::imscpConfig{'USER_HOME_DIR'}/$self->{user_home}/$self->{subdomain_alias_mount}";
	$file_name		=~ s~/~~g;
	$hDir			=~ s~/+~/~g;

	$self->{ftpd} = {
		FILE_NAME	=> $file_name,
		PATH		=> $hDir
	};

	debug('Ending...');
	0;
}
1;
