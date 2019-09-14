# Camel
Camel is a Perl5-based service framework and standardized RPC running in AWS Lambda.

It is a remake of [Laputa](https://github.com/leeym/laputa) which is inspired by [Wealthfront's Query Engine](https://www.slideshare.net/julienwetterwald/wealthfronts-query-engine), and is built on top of [aws-lambda-perl5-layer](https://github.com/moznion/aws-lambda-perl5-layer)

You can simply write a script with `.pl` extension and invoke it with ["qp0p1"](https://image.slidesharecdn.com/20120308wealthfrontsqueryenginesquare-120509010632-phpapp02/95/wealthfronts-query-engine-13-728.jpg?cb=1336526883) serialization, where `q=echo&p0=foo&p1=bar` will call `perl echo.pl foo bar` internally.

# Invoke
* `curl -s -X POST https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`
* `curl -s -X POST -d 'q=echo&p0=foobar' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`
* `curl -s -X POST -d 'q=env' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`
* `curl -s -X POST -d 'q=wbsc' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`

# Error handling
* `curl -s -D - -X POST -d 'q=A&q=b' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default` => 400
* `curl -s -D - -X POST -d 'q=nonexistent' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default` => 404
* `curl -s -D - -X POST -d 'q=die' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default` => 500

# Deploy
The following example is in Oregon (us-west-2) so please replace it with your own region.

Steps to deploy Camel in AWS Lambda.
1. [Create function](https://us-west-2.console.aws.amazon.com/lambda/home?region=us-west-2#/create/function)
   * Function name: Name it whatever you like. In this example I simply call it "Camel"
   * Runtime: "Provide your own boostrap"
   * Execution role: "Use an existing role" if you already have one, otherwise "Create a new role with basic Lambda permissions"
2. [Add a layer](https://us-west-2.console.aws.amazon.com/lambda/home?region=us-west-2#/add/layer?function=Camel)
   * Provide a layer version ARN: "arn:aws:lambda:us-west-2:652718333417:layer:perl-5_28-layer:1"
3. [Configuration](https://us-west-2.console.aws.amazon.com/lambda/home?region=us-west-2#/functions/Camel?tab=graph)
   * Basic settings
      * Timeout: 0 min 28 sec
   * Function code
      * Runtime: "Custom runtime"
      * Handler: Not in use. You can put whatever you want or leave it as is. Default: "hello.handler"
      * Code entry type: "Upload a .zip file" -> "Upload" -> "Save"

Steps to expose Camel in AWS API Gateway
1. [Create API](https://us-west-2.console.aws.amazon.com/apigateway/home?region=us-west-2#/apis/create)
   * Choose the protocol: REST
   * Create new API: New API
   * Settings:
      * API name: Normally we name it based on the Lambda function, for example "Camel"
      * Endpoint Type: Regional
2. Actions > Create Method > Any > "V"
   * Integration type: Lambda function
   * Use Lambda Proxy integration: "V"
   * Lambda Function: Camel
3. Actions > Deploy API
   * Deployment stage: New Stage > Stage name: "default" > "Deploy"
4. Copy the "Invoke URL".
