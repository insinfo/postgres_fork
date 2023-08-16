FROM postgres:14.3
ADD pg_hba.conf /var/lib/postgresql/data/
ADD postgresql.conf /var/lib/postgresql/data/
COPY init.sql /docker-entrypoint-initdb.d/
RUN apt-get update 
RUN apt-get -y install tzdata 
RUN apt-get -y install locales
RUN localedef -i pt_BR -c -f CP1252 -A /usr/share/locale/locale.alias pt_BR.CP1252
#RUN sed -i -e 's/# pt_BR.CP1252 CP1252/pt_BR.UTF-8 UTF-8/pt_BR ISO-8859-1/pt_BR/' /etc/locale.gen && \
 #   dpkg-reconfigure --frontend=noninteractive locales && \
 #   update-locale LANG=pt_BR.CP1252
RUN echo 'pt_BR.CP1252 CP1252' | tee -a /etc/locale.gen > /dev/null
RUN echo 'pt_BR ISO-8859-1' | tee -a /etc/locale.gen > /dev/null
RUN echo 'pt_BR.UTF-8 UTF-8' | tee -a /etc/locale.gen > /dev/null
#RUN sed -i '/pt_BR.CP1252/s/^# //g' /etc/locale.gen 
RUN locale-gen pt_BR.UTF-8  
RUN locale-gen pt_BR
RUN locale-gen
RUN locale -a

ENV LANG pt_BR.CP1252  
#ENV LANGUAGE pt_BR:pt:en
#ENV LC_ALL pt_BR.CP1252    
