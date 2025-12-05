# From Magento root outsite warden container
warden env exec -T php-fpm env \
  bash <<'RELOAD_MAGENTO'

set -e

cd /var/www/html
cd /var/www/html
php bin/magento maintenance:enable
rm -rf generated/code/*
rm -rf generated/metadata/*
rm -rf var/cache/*
rm -rf var/page_cache/*

composer dump-autoload
php bin/magento setup:upgrade
php bin/magento setup:di:compile
php bin/magento indexer:reindex
php bin/magento setup:static-content:deploy -f
php bin/magento cache:flush
php bin/magento maintenance:disable

RELOAD_MAGENTO
