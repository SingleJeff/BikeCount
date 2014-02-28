#!/usr/bin/perl

# run with:   /usr/local/bin/corona --E development signup.pl 

use strict;

use lib 'continuity/lib'; # dev version
use Continuity;
use Continuity::Adapt::PSGI;

use Data::Dumper;
use IO::Handle;
use Text::CSV;
use List::MoreUtils 'zip';
use Cwd;
use JSON::PP;
# use Geo::Coder::RandMcnally; # overlaps most of the intersections
# use Geo::Coder::Geocoder::US;
use Geo::Coder::TomTom;
use XXX;
use Carp;
use HTML::Scrubber;

use repop 'repop';
use csv;
use geo;

$SIG{USR1} = sub {
    Carp::confess $@;
};

open my $log, '>>', 'signup.log' or die $!;
$log->autoflush(1);

sub read_signupform {
    my $fn = shift;
    open my $fh, '<', $fn or die "$fn: $!";
    read $fh, my $signupform, -s $fh;
    close $fh;
    return $signupform;
}

# init volunteers

my $volunteers = csv->new('volunteers.csv', 0);

for my $column (qw/first_name last_name phone_number email_address training_session training_session_comment intersections comments/) {
    $volunteers->add_column($column) if ! grep $_ eq $column, @{ $volunteers->headers };
}

# init count sites

my $count_sites = csv->new('count_sites.csv', 1);

geo::geocode( $count_sites );

#

#my $am_shifts = qq{
#    <li class="ss-choice-item"><label class="ss-choice-label"><input name="shift" class="ss-q-radio" type="radio" value="ATue">Tuesday AM</label></li>
#    <li class="ss-choice-item"><label class="ss-choice-label"><input name="shift" class="ss-q-radio" type="radio" value="AWed">Wednesday AM</label></li>
#    <li class="ss-choice-item"><label class="ss-choice-label"><input name="shift" class="ss-q-radio" type="radio" value="AThu">Thursday AM</label></li>
#};
#
#my $pm_shifts = qq{
#    <li class="ss-choice-item"><label class="ss-choice-label"><input name="shift" class="ss-q-radio" type="radio" value="PTue">Tuesday PM</label></li>
#    <li class="ss-choice-item"><label class="ss-choice-label"><input name="shift" class="ss-q-radio" type="radio" value="PWed">Wednesday PM</label></li>
#    <li class="ss-choice-item"><label class="ss-choice-label"><input name="shift" class="ss-q-radio" type="radio" value="PThu">Thursday PM</label></li>
#};

sub get_pois {

    my $all_flag = shift;

    # get points of interest that haven't yet been (completely) allocated

    my $pending_sites;

    if( $all_flag ) {
        for my $site ( $count_sites->rows ) {
            $pending_sites->{ $site->location_id . 'A' } = $site;
            $pending_sites->{ $site->location_id . 'P' } = $site;
        }
    } else {
        # normal case:  only show what's still available
        $pending_sites = get_pending_sites();
    }


    my @pois = sort { $a->{desc} cmp $b->{desc} } grep { $_->{lat} and $_->{lon} and $_->{desc} } map { 
        {
            lat  => $_->latitude,
            lon  => $_->longitude,
            desc => $_->location_id . ': ' . $_->location_N_S . ' and ' . $_->location_W_E,
            id   => $_->location_id,
        }
    } values %$pending_sites; # $count_sites->rows;
    # warn Data::Dumper::Dumper \@pois;

    return \@pois;
}


sub get_pending_sites {

    # returns a hash of 101A style codes to site records from $count_sites
    # takes an optional location_id argument to restrict results

    my $loc_id = shift;

    my %sites;
    my %double_up;

    for my $site ( $count_sites->rows ) {
        next if $loc_id and $loc_id ne $site->location_id;
        next if ! $site->vols_needed;
        $double_up{ $site->location_id } = $site->vols_needed;
        $sites{ $site->location_id . 'A' } = $site;  # available until found otherwise
        $sites{ $site->location_id . 'P' } = $site;
    }

    for my $volunteer ( $volunteers->rows ) {
        my $intersections = $volunteer->intersections or next;
        my @intersections = split m/,/, $intersections or next;
        for my $intersection ( @intersections ) {
            my( $location_id_ampm ) = $intersection =~ m/(\d+[AP])/;  # ignore any trailing day of the week information
            if( $double_up{ $location_id_ampm } ) {
                $double_up{ $location_id_ampm }--;
             } else {
                delete $sites{ $location_id_ampm };  # taken or no volunteers requested this year
            }
        }
    }

    # update unassigned_sites

    if( ! $loc_id ) {
        open my $fh, '>', 'unassigned_locations.txt' or warn $!;

        for my $id (sort { $a cmp $b } keys %sites) {
            my $site = $sites{$id};
            $fh and $fh->print($id, ': ', $site->location_N_S, ' and ', $site->location_W_E, "\n");
        }
    }

    return \%sites;

}

sub get_compat_shifts {
    my $assignments = shift;
    my $pending_shifts = shift;
    my %assignment_by_date_shift;
    for my $assignment ( @$assignments ) {
        my( $location_id, $ampm, $day ) = $assignment =~ m/^(\d+)([AP])([A-Z][a-z]{2})$/ or die $assignment;
        $assignment_by_date_shift{ "$ampm$day" } = $location_id; # not checking here for double booked
    }       
    my @okay_shifts;
    for my $shift (@$pending_shifts) {
        my( $location_id, $ampm ) = $shift =~ m/^(\d+)([AP])$/ or die $shift;
        for my $day ('Tue', 'Wed', 'Thu') {
            push @okay_shifts, "$location_id$ampm$day" if ! exists $assignment_by_date_shift{ "$ampm$day" };
        }
    }
    return @okay_shifts;

}

sub get_assignments {
    my $email_address = shift or return;
    my $volunteer = $volunteers->find('email_address', $email_address, sub { lc $_[0] } ) or return;
    my $assignments = $volunteer->intersections or return;
    my @assignments = split m/,/, $assignments or return;
    return wantarray ? @assignments : \@assignments;
}

sub get_assignments_text {

    # returns a textual list of assignments for a given user

    my $email_address = shift or return;
    my @assignments = get_assignments( $email_address );

    my $parsed_assignments = '';

    for my $intersection (@assignments) {
        my( $location_id, $ampm, $day ) = $intersection =~ m/(\d+)([AP])(.*)/;
        my $site = $count_sites->find('location_id', $location_id);
        $parsed_assignments .= "$day $ampm" .'M ' . $site->location_N_S . ' and ' . $site->location_W_E . " ($location_id)<br>\n";
    }

    return $parsed_assignments;

}

sub update_volunteer_data {

    # save user entered form data

    # XXX should subclass the volunteer records and add this logic there

    my $signup_data = shift;

    my $error;

    my $volunteer = $volunteers->find('email_address', $signup_data->{email_address} );

    if( ! $volunteer ) {
        $volunteer = $volunteers->add;
warn "adding a new volunteer record";
        $volunteer->email_address = $signup_data->{email_address};
    }

    for my $key ( qw/first_name last_name phone_number training_session training_session_comment comments/ ) {
        if( $signup_data->{ $key } ) {
            $volunteer->{ $key } = $signup_data->{ $key };
            $log->print("setting $key = $signup_data->{$key} for user $signup_data->{email}\n");
        }
    }

    if( $signup_data->{location_id} ) {

        # record assignment

        my $assignment = $signup_data->{location_id};  # eg: 130: Country Club Wy and Alameda Dr
        $log->print("location_id = $assignment for user $signup_data->{email}\n");
        $assignment =~ s{:.*}{};  # comes in the form of eg "101: Hardy and Southern"
        $assignment .= $signup_data->{'shift'};  # eg: ATue
        $log->print("shift = $signup_data->{'shift'} for user $signup_data->{email}\n");
        $assignment =~ m/^\d{3}[AP][A-Z][a-z][a-z]$/ or do {
            warn "bad assignment: ``$assignment''";
            $log->print("ERROR --> bad assignement: ``$assignment''\n");
            return "<br><br>Error:  Pick a location and a shift";
        };
        $log->print("new assignment: $assignment\n");

        my $intersections = $volunteer->intersections;
        $intersections .= ',' if $intersections;
        $intersections .= $assignment;
        $volunteer->intersections = $intersections;

        $error = '<br><br>Count shift recorded -- thanks!';


    }

    $volunteers->write;
    chmod 0640, "volunteers.csv";

    return $error;

}

# start server

my $server = Continuity->new(
    # adapter => Continuity::Adapt::PSGI->new( docroot => Cwd::getcwd() ),
    port => 5000,
    # path_session => 1,
    # debug => 3,
    # mapper   => Continuity::Mapper->new(
    #     callback => \&main,
    #     path_session => 1,
    #     cookie_session => 'sid',
    # ),
);


my $scrubber = HTML::Scrubber->new;

sub main {
    my $req = shift;

    my $signup_data = { };

    while(1) {

        $count_sites->reload;
        $volunteers->reload;

        my $action = $req->param('action') || 'default';

        my %new_params = $req->params;
        # warn "new params: " . Data::Dumper::Dumper \%new_params;
        for my $new_param (keys %new_params) {
            next if $new_param eq 'action';
            $signup_data->{ $new_param } = $scrubber->scrub( $new_params{ $new_param } );
        }
        $log->print("signup_data: " . Data::Dumper::Dumper $signup_data );

        my $error = update_volunteer_data( $signup_data ) || '' if $signup_data->{email_address} and $action eq 'register';

        if( $action eq 'get_times_for_intersection' ) {
            
            my $location_id = $scrubber->scrub( $req->param('location_id') );
            $location_id =~ s{:.*}{};  # comes in the form of eg "101: Hardy and Southern"

            my $sites = get_pending_sites( $location_id );
            $sites = [ sort { $a cmp $b } keys %$sites ];
warn "email = " . $signup_data->{email_address};
warn "pending sites = @$sites";
            my @open_shifts = get_compat_shifts( scalar(get_assignments( $signup_data->{email_address})), $sites );
warn "open_shifts = @open_shifts";

            for my $shift ( @open_shifts ) {
                my( $location_id, $ampm, $day ) = $shift =~ m/^(\d{3})([AP])([A-Z][a-z][a-z])$/;
                # warn "shift = $shift day = $day ampm = $ampm";
                my $nice_day = { Tue => 'Tuesday', Wed => 'Wednesday', Thu => 'Thursday', }->{$day};
                my $nice_ampm = { P => 'PM', A => 'AM', }->{$ampm};
                $req->print(qq{    <li class="ss-choice-item"><label class="ss-choice-label"><input name="shift" class="ss-q-radio" type="radio" value="$ampm$day"/>$nice_day $nice_ampm</label></li>\n});
            }

            if( ! @open_shifts ) {
                $req->print(qq{Either your AM or PM is full and your schedule cannot accommodate these shifts: @$sites.<br>\n});
            }

        } elsif( $action eq 'get_assignments' ) {

            my $assignments = get_assignments_text( $signup_data->{email_address} );
            $req->print( $assignments || 'No current assignments for that email address' );

        } else {
  
            my $all = $req->param('all');  # show all intersections, even those that are full?

            my $signupform = read_signupform('signup1.html'); # every time, during dev

            my $html = repop( $signupform, $signup_data );

            my $pois = get_pois( $all );
            my $json_pois = encode_json $pois;
            $html =~ s/POIS/$json_pois/;

# XXX
# convert $pois to $available_intersections
            my $available_intersections = '';
            for my $poi (@$pois) {
                $available_intersections .= qq{
                    <option value="@{[ $poi->{desc} ]}">@{[ $poi->{desc} ]}</option>
                };
            }
            $html =~ s/AVAILABLEINTERSECTIONS/$available_intersections/;

            my $assignments = get_assignments_text( $signup_data->{email_address} );
            $html =~ s/CURRENT_ASSIGNMENTS/$assignments/;

            my $comments = $signup_data->{comments} || '';
            $html =~ s/COMMENTS/$comments/;

            $html =~ s/ERROR/$error/;

            $req->print( $html );

        }
   
        $req->next; # Get their response to that

    }
}

$server->loop; # has to be last for plack


