package MusicBrainz::Server::Controller::WS::js;

use Moose;
BEGIN { extends 'MusicBrainz::Server::ControllerBase::WS::js'; }

use Data::OptList;
use Encode qw( decode encode );
use JSON qw( encode_json );
use List::UtilsBy qw( uniq_by );
use MusicBrainz::Server::WebService::Validator;
use MusicBrainz::Server::Filters;
use MusicBrainz::Server::Data::Search qw( escape_query alias_query );
use MusicBrainz::Server::Validation qw( is_guid );
use Readonly;
use Text::Trim;

# This defines what options are acceptable for WS calls
my $ws_defs = Data::OptList::mkopt([
    "medium" => {
        method => 'GET',
        inc => [ qw(recordings) ],
        optional => [ qw(q artist tracks limit page timestamp) ]
    },
    "cdstub" => {
        method => 'GET',
        optional => [ qw(q artist tracks limit page timestamp) ]
    },
    "freedb" => {
        method => 'GET',
        optional => [ qw(q artist tracks limit page timestamp) ]
    },
    "cover-art-upload" => {
        method => 'GET',
    },
    "entity" => {
        method => 'GET',
        inc => [ qw(rels) ]
    },
    "events" => {
        method => 'GET'
    }
]);

with 'MusicBrainz::Server::WebService::Validator' =>
{
     defs => $ws_defs,
     version => 'js',
};

sub entities {
    return {
        'Artist' => 'artist',
        'Work' => 'work',
        'Recording' => 'recording',
        'ReleaseGroup' => 'release-group',
        'Release' => 'release',
        'Label' => 'label',
        'URL' => 'url',
        'Area' => 'area',
        'Place' => 'place',
        'Instrument' => 'instrument',
        'Series' => 'series',
    };
}

sub medium : Chained('root') PathPart Args(1) {
    my ($self, $c, $id) = @_;

    my $medium = $c->model('Medium')->get_by_id($id);
    $c->model('MediumFormat')->load($medium);
    $c->model('MediumCDTOC')->load_for_mediums($medium);
    $c->model('Track')->load_for_mediums($medium);
    $c->model('ArtistCredit')->load($medium->all_tracks);
    $c->model('Artist')->load(map { @{ $_->artist_credit->names } }
                              $medium->all_tracks);

    my $inc_recordings = $c->stash->{inc}->recordings;

    if ($inc_recordings) {
        $c->model('Recording')->load($medium->all_tracks);
        $c->model('ArtistCredit')->load(map $_->recording, $medium->all_tracks);
    }

    my $ret = $c->stash->{serializer}->_medium($medium, $inc_recordings);

    $ret->{tracks} = [
        map $c->stash->{serializer}->_track($_), $medium->all_tracks
    ];

    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body(encode_json($ret));
}

sub freedb : Chained('root') PathPart Args(2) {
    my ($self, $c, $category, $id) = @_;

    my $response = $c->model('FreeDB')->lookup($category, $id);

    unless (defined $response) {
        $c->stash->{error} = "$category/$id not found";
        $c->detach('not_found');
    }

    my $ret = { toc => "" };
    $ret->{tracks} = [ map {
        {
            name => $_->{title},
            artist => $_->{artist},
            length => $_->{length},
        }
    } @{ $response->tracks } ];

    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body(encode_json($ret));
};

sub cdstub : Chained('root') PathPart Args(1) {
    my ($self, $c, $id) = @_;

    my $cdstub_toc = $c->model('CDStubTOC')->get_by_discid($id);
    my $ret = {
        toc => "",
        tracks => []
    };

    if ($cdstub_toc)
    {
        $c->model('CDStub')->load($cdstub_toc);
        $c->model('CDStubTrack')->load_for_cdstub($cdstub_toc->cdstub);
        $cdstub_toc->update_track_lengths;

        $ret->{toc} = $cdstub_toc->toc;
        $ret->{tracks} = [ map {
            {
                name => $_->title,
                artist => $_->artist,
                length => $_->length,
                artist => $_->artist,
            }
        } $cdstub_toc->cdstub->all_tracks ];
    }

    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body(encode_json($ret));
}

sub tracklist_results {
    my ($self, $c, $results) = @_;

    my @output;

    my @gids = map { $_->entity->gid } @$results;

    my @releases = values %{ $c->model('Release')->get_by_gids(@gids) };
    $c->model('Medium')->load_for_releases(@releases);
    $c->model('MediumFormat')->load(map { $_->all_mediums } @releases);
    $c->model('ArtistCredit')->load(@releases);

    for my $release ( @releases )
    {
        next unless $release;

        my $count = 0;
        for my $medium ($release->all_mediums)
        {
            $count += 1;

            push @output, {
                gid => $release->gid,
                name => $release->name,
                position => $count,
                format => $medium->format_name,
                medium => $medium->name,
                comment => $release->comment,
                artist => $release->artist_credit->name,
                medium_id => $medium->id,
            };
        }
    }

    return uniq_by { $_->{medium_id} } @output;
};

sub disc_results {
    my ($self, $type, $results) = @_;

    my @output;
    for (@$results)
    {
        my %result = (
            discid => $_->entity->discid,
            name => $_->entity->title,
            artist => $_->entity->artist,
        );

        $result{year} = $_->entity->year if $type eq 'freedb';
        $result{category} = $_->entity->category if $type eq 'freedb';

        $result{comment} = $_->entity->comment if $type eq 'cdstub';
        $result{barcode} = $_->entity->barcode->format if $type eq 'cdstub';

        push @output, \%result;
    }

    return @output;
};

sub disc_search {
    my ($self, $c, $type) = @_;

    my $query = escape_query(trim $c->stash->{args}->{q});
    my $artist = escape_query($c->stash->{args}->{artist});
    my $tracks = escape_query($c->stash->{args}->{tracks});
    my $limit = $c->stash->{args}->{limit} || 10;
    my $page = $c->stash->{args}->{page} || 1;

    # FIXME Should be able to remove the 'OR' when Lucene 4.0 comes out
    my $title = $type eq 'release' ? "release:($query*) OR release:($query)" : "$query* OR $query";
    my @query;

    push @query, $title if $query;
    push @query, "artist:($artist)" if $artist;
    push @query, ($type eq 'release' ? "tracksmedium:($tracks)" : "tracks:($tracks)") if $tracks;

    $query = join(" AND ", @query);

    my $no_redirect = 1;
    my $response = $c->model('Search')->external_search(
        $type, $query, $limit, $page, 1, undef);

    my @output;

    if ($response->{pager})
    {
        my $pager = $response->{pager};

        @output = $type eq 'release' ?
            $self->tracklist_results($c, $response->{results}) :
            $self->disc_results($type, $response->{results});

        push @output, {
            pages => $pager->last_page,
            current => $pager->current_page
        };
    }
    else
    {
        # If an error occurred just ignore it for now and return an
        # empty list.  The javascript code for autocomplete doesn't
        # have any way to gracefully report or deal with
        # errors. --warp.
    }

    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body(encode_json(\@output));
};

sub medium_search : Chained('root') PathPart('medium') Args(0) {
    my ($self, $c) = @_;

    return $self->disc_search($c, 'release');
}

sub cdstub_search : Chained('root') PathPart('cdstub') Args(0) {
    my ($self, $c) = @_;

    return $self->disc_search($c, 'cdstub');
};

sub freedb_search : Chained('root') PathPart('freedb') Args(0) {
    my ($self, $c) = @_;

    return $self->disc_search($c, 'freedb');
};

sub cover_art_upload : Chained('root') PathPart('cover-art-upload') Args(1)
{
    my ($self, $c, $gid) = @_;

    my $id = $c->request->params->{image_id} // $c->model('CoverArtArchive')->fresh_id;
    my $bucket = 'mbid-' . $gid;

    my %s3_policy;
    $s3_policy{mime_type} = $c->request->params->{mime_type};
    $s3_policy{redirect} = $c->uri_for_action('/release/cover_art_uploaded', [ $gid ])->as_string()
        if $c->request->params->{redirect};

    my $data = {
        action => DBDefs->COVER_ART_ARCHIVE_UPLOAD_PREFIXER($bucket),
        image_id => "$id",
        formdata => $c->model('CoverArtArchive')->post_fields($bucket, $gid, $id, \%s3_policy)
    };

    $c->res->headers->header( 'Cache-Control' => 'no-cache', 'Pragma' => 'no-cache' );
    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body(encode_json($data));
}

sub entity : Chained('root') PathPart('entity') Args(1)
{
    my ($self, $c, $gid) = @_;

    unless (is_guid($gid)) {
        $c->stash->{error} = "$gid is not a valid MusicBrainz ID.";
        $c->detach('bad_req');
        return;
    }

    my $entity;
    my $type;
    for (keys %{ $self->entities }) {
        $type = $_;
        $entity = $c->model($type)->get_by_gid($gid);
        last if defined $entity;
    }

    unless (defined $entity) {
        $c->stash->{error} = "The requested entity was not found.";
        $c->detach('not_found');
        return;
    }

    my $js_class = "MusicBrainz::Server::Controller::WS::js::$type";

    $js_class->_load_entities($c, $entity);

    my $serialization_routine = $js_class->serialization_routine;
    my $data = $c->stash->{serializer}->$serialization_routine($entity);

    my $relationships = $c->stash->{serializer}->serialize_relationships($entity->all_relationships);
    $data->{relationships} = $relationships if @$relationships;

    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body(encode_json($data));
}

sub default : Path
{
    my ($self, $c, $resource) = @_;

    $c->stash->{serializer} = $self->get_serialization($c);
    $c->stash->{error} = "Invalid resource: $resource";
    $c->detach('bad_req');
}

sub events : Chained('root') PathPart('events') {
    my ($self, $c) = @_;

    my $events = $c->model('Statistics')->all_events;

    $c->res->content_type($c->stash->{serializer}->mime_type . '; charset=utf-8');
    $c->res->body(encode_json($events));
}

no Moose;
1;

=head1 COPYRIGHT

Copyright (C) 2010 MetaBrainz Foundation

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
