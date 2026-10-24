/* Disposable libgpod fixture. Never point this helper at a real device. */
#include "itdb.h"
#include "ipod-api.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    assert(argc == 2);
    GError *error = NULL;
    assert(itdb_init_ipod(argv[1], "MA450", "Test iPod", &error));
    Itdb_iTunesDB *db = itdb_parse(argv[1], &error);
    assert(db);
    Itdb_Track *track = itdb_track_new();
    track->title = g_strdup("History");
    track->tracklen = 1000;
    track->rating = 80;
    track->playcount = 42;
    itdb_track_add(db, track, -1);
    itdb_playlist_add_track(itdb_playlist_mpl(db), track, -1);
    assert(itdb_write(db, &error));
    itdb_free(db);
    IPodDB *handle = ipod_open(argv[1], NULL);
    assert(handle);
    IPodTagMetadata tags = {0};
    tags.title = "Updated";
    tags.genre = "Rock";
    tags.albumArtist = "Album Artist";
    tags.discNumber = 2;
    tags.trackTotal = 12;
    tags.compilation = 1;
    IPodResult result = ipod_set_track_tags(handle, 0, &tags);
    assert(result.success);
    assert(ipod_save(handle).success);
    ipod_close(handle);
    db = itdb_parse(argv[1], &error);
    assert(db);
    track = db->tracks->data;
    assert(track->rating == 80 && track->playcount == 42);
    assert(strcmp(track->title, "Updated") == 0);
    assert(strcmp(track->genre, "Rock") == 0);
    assert(track->cd_nr == 2 && track->tracks == 12 && track->compilation);
    /* Leave an empty DB for the Swift transfer tests. */
    itdb_playlist_remove_track(itdb_playlist_mpl(db), track);
    itdb_track_remove(track);
    assert(itdb_write(db, &error));
    itdb_free(db);
    return 0;
}
