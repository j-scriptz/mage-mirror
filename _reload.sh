# From Magento root
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