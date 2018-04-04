# Icinga2 - gd-downtime.sh

Kerberos is used for authentication to Icinga2 API - run kinit before use

*Usage*:

Downtime set:
* -d datacenter (na, eu1, ca1)
* -t ticket
* -w date in format YYYY-MM-DD
* -r range in format start(HH:MM)-stop(HH-MM) - multiple ranges has to be delimited by coma (see examples)

*Examples*:
```
gd-downtime.sh -t GD1234 -d ca1 -w 2018-03-01 -r 08:00-12:00
gd-downtime.sh -t GD1235 -d eu1 -w 2018-12-24 -r 08:00-12:00,16:00-18:00
```

Downtime unset:
*  -l list of set downtimes
*  -u unset given downtime

*Example*:
 ```
 gd-downtime.sh -u na-down-GD1234
 ```
