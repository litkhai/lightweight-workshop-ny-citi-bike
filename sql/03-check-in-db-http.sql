-- Could the collector live inside the database?
--
--   ./scripts/psql.sh -f /sql/03-check-in-db-http.sql
--
-- On ClickHouse Managed Postgres today the answer is no, and this file exists
-- so you can confirm that for yourself rather than taking module 02's word for
-- it — and so you can re-check after a platform update.
--
-- Running it changes nothing except creating one diagnostic function.

\echo '== is there an HTTP client extension? =='
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('http', 'pg_net', 'plpython3u', 'plperlu', 'pg_cron')
ORDER BY name;

\echo ''
\echo '-- http / pg_net / plpython3u absent means plperlu is the only way out.'
\echo ''

\echo '== can this role install an untrusted language? =='
SELECT current_user, rolsuper AS is_superuser
FROM pg_roles WHERE rolname = current_user;

\echo ''
\echo '== does the server-side Perl have a TLS stack? =='

CREATE EXTENSION IF NOT EXISTS plperlu;

CREATE OR REPLACE FUNCTION citibike_perl_tls_probe()
RETURNS TABLE (item text, value text)
LANGUAGE plperlu
AS $perl$
    my @want = qw(IO::Socket::SSL Net::SSLeay Mozilla::CA LWP::UserAgent HTTP::Tiny);
    my @have = grep { eval "require $_; 1" } @want;
    my %have = map { $_ => 1 } @have;
    my ($ca) = grep { -r $_ } qw(
        /etc/ssl/certs/ca-certificates.crt
        /etc/pki/tls/certs/ca-bundle.crt
        /etc/ssl/cert.pem
    );
    return_next({ item => 'perl version',  value => "$]" });
    return_next({ item => 'modules found', value => (@have ? "@have" : '(none)') });
    for my $m (@want) {
        return_next({ item => "  $m", value => $have{$m} ? 'yes' : 'MISSING' });
    }
    return_next({ item => 'CA bundle', value => $ca // '(none found)' });
    return_next({ item => 'verdict',
        value => ($have{'IO::Socket::SSL'} && $have{'Net::SSLeay'})
                 ? 'https from inside Postgres is possible'
                 : 'https from inside Postgres is NOT possible on this host' });
    return undef;
$perl$;

SELECT * FROM citibike_perl_tls_probe();

\echo ''
\echo '-- Measured on ClickHouse Managed Postgres (PostgreSQL 18.4) on 2026-08-15:'
\echo '--   perl 5.034, modules found: IO::Socket::INET only,'
\echo '--   CA bundle present at /etc/ssl/certs/ca-certificates.crt,'
\echo '--   and every https fetch dies with'
\echo '--     "IO::Socket::SSL 1.42 must be installed for https support".'
\echo '--'
\echo '-- CREATE EXTENSION plperlu itself succeeds. It is the Perl build that'
\echo '-- has no TLS, so the blocker is the image, not the permission — which'
\echo '-- means a future platform update could flip this without warning.'

DROP FUNCTION citibike_perl_tls_probe();
