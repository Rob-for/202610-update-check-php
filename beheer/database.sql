-- Eenmalig uitvoeren op de MySQL/MariaDB-server (als beheerder), bijv.:
--   mysql -u root -p < database.sql
-- Vervang 'KIES-EEN-STERK-WACHTWOORD' en eventueel '%' door het IP van de UpdataServer-LXC.
-- De tabellen maakt Updatebeheer daarna zelf aan.

CREATE DATABASE IF NOT EXISTS updatebeheer CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'updatebeheer'@'%' IDENTIFIED BY 'KIES-EEN-STERK-WACHTWOORD';
GRANT ALL PRIVILEGES ON updatebeheer.* TO 'updatebeheer'@'%';
FLUSH PRIVILEGES;
