=head1 NAME

 iMSCP::Package::Abstract - Abstract class for i-MSCP packages

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2018 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package iMSCP::Package::Abstract;

use strict;
use warnings;
use iMSCP::Boolean;
use iMSCP::Database;
use iMSCP::EventManager;
use parent qw/ Common::SingletonClass iMSCP::Installer::AbstractActions iMSCP::Uninstaller::AbstractActions iMSCP::Modules::AbstractActions /;

=head1 DESCRIPTION

 Abstract class for i-MSCP packages.

 i-MSCP packages extend/implement core features or provide additional features
 and/or services.

 This class is meant to be subclassed by i-MSCP package classes.

=head1 CLASS METHODS

=over 4

=item getPriority( \%data )

 Get package priority

 Return int package priority

=cut

sub getPriority
{
    my ( $class ) = @_;

    0;
}

=item checkRequirements

 Check package requirements

 A package will be made available only if all requirements are met.

 Return TRUE if all requirement are met, FALSE otherwise

=cut

sub checkRequirements
{
    my ( $class ) = @_;

    TRUE;
}

=back

=head1 PUBLIC METHODS

=over 4

=item getConfig()

 Get package configuration
 
 Return hashref

=cut

sub getConfig( )
{
    my ( $self ) = @_;

    $self->{'config'} || {};
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 See Common::SingletonClass::_init()

=cut

sub _init
{
    my ( $self ) = @_;

    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self->{'dbh'} = iMSCP::Database->factory();
    $self;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
