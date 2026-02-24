
## Process
```mermaid
flowchart LR
  A[Start] --> B[Database Refresh]
  B[PROD to Delphix db import] --> C[Deidentification]
  C[Deidentification] --> D[SQL Extract]
  D[SQL Extract] --> E[Copy to Utility ctxodclnutil001]
  E[Copy to Utility ctxodclnutil001] --> F[SFTP MOVEit]
```
## Infra
```mermaid
flowchart LR
A[**CTODCLNORA004**<br>10.40.26.211] --> B[**ctxodclnutil001**<br>10.40.26.175]

```
## Contacts
| App | Contact |
| ----------- | ----------- |
| MOVEit | thughes39@gainwelltechnologies.com |
| Genius | chandrakanth.motlakunta@gainwelltechnologies.com |
| DeIdentification | poornima.dhanasekaran@gainwelltechnologies.com |

## Notes
### SFTP
- MOVEit does not like .gz, needs to be .tar.gz

### MOVEit
- To do automation need service user. SSH key tied to Gainwell login. Can't add Linux SSH Key in MOVEit per security 
- mft.gainwelltechnologies.com - **54.80.94.146**

### Scripts
tar

`tar -czf AIM_T_RE_DEATH_CHG_0.tar.gz AIM_T_RE_DEATH_CHG_0_test.dat`

## Tasks
- [x] Create scripts for copy
- [x] Create script for SFTP push
- [ ] Check on incremental refresh process 