## Sprint: Fix indempotency issues

### Current State :

 1. Mobile App Written in Dart/Flutter that consume Google Firebase services (a. db, b: authentication/registration service)
 2. a scripts folder that scrap and integrate data to firebase.


### Objective and Todos

1. when integrating (I mean upload and insert data "json" format in firebase) the firebase documents are inconsistent.
    a. duplicated docs
    b. missing data (stations)
2. Refactoring the way that we have a separation of concerns (If it'is Ok than do nothing)