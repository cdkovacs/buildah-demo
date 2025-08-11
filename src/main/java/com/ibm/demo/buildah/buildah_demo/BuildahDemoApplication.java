package com.ibm.demo.buildah.buildah_demo;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
@Slf4j
public class BuildahDemoApplication {

	public static void main(String[] args) {
		log.info("Starting BuildahDemoApplication... (version: {})", BuildahDemoApplication.class.getPackage().getImplementationVersion());
		SpringApplication.run(BuildahDemoApplication.class, args);
	}

}
