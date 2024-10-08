# Camel
Camel is a Perl5-based service framework and standardized RPC running in AWS Lambda.

It is a remake of [Laputa](https://github.com/leeym/laputa) which is inspired by [Wealthfront's Query Engine](https://www.slideshare.net/julienwetterwald/wealthfronts-query-engine), and is built on top of [aws-lambda-perl5-layer](https://github.com/moznion/aws-lambda-perl5-layer)

You can simply write a script with `.pl` extension and invoke it with ["qp0p1"](https://image.slidesharecdn.com/20120308wealthfrontsqueryenginesquare-120509010632-phpapp02/95/wealthfronts-query-engine-13-728.jpg?cb=1336526883) serialization.

# Develop
* Clone this repository
* Install Docker
* Write your own script, for example `hello.pl`
* `make build` to create `func.zip` so you can upload it later.

# Examples
* echo.pl - something basic, for example print any parameter
* env.pl - with Module(s), probably from CPAN
* die.pl - simulate if your call `die` in your code, STDOUT will be ignored and STDERR will be returned
* help.pl - built-in script to list all queries
* wbsc.pl - a working example to parse the calendar for WBSC and create an iCalendar
* wbc.pl - a working example to parse the calendar from WBC and create an iCalendar

# Deploy
The following example is in Oregon (us-west-2) so please replace it with your own region.

Steps to deploy Camel in AWS Lambda.
1. [Create function](https://us-west-2.console.aws.amazon.com/lambda/home?region=us-west-2#/create/function)
   * Function name: Name it whatever you like. In this example I simply call it `Camel`
   * Runtime: `Amazon Linux 2023`
   * Architecture: Either one is fine. I use `amd64`
   * Execution role: `Use an existing role` if you already have one, otherwise `Create a new role with basic Lambda permissions`
2. [Add a layer](https://us-west-2.console.aws.amazon.com/lambda/home?region=us-west-2#/add/layer?function=Camel)
   * Provide a layer version ARN: `arn:aws:lambda:us-west-2:445285296882:layer:perl-5-40-runtime-al2023-arm64:2`
   * For other layers, please check: [AWS::Lambda::AL2023](https://metacpan.org/pod/AWS::Lambda::AL2023)
3. [Code](https://us-west-2.console.aws.amazon.com/lambda/home?region=us-west-2#/functions/Camel?tab=code)
   * Runtime settings
      * Runtime: `Amazon Linux 2023`
      * Handler: `handler.handle`

Steps to expose Camel in AWS API Gateway
1. [Create API](https://us-west-2.console.aws.amazon.com/apigateway/home?region=us-west-2#/apis/create)
   * Choose the protocol: REST API
   * Create new API: New API
   * Settings:
      * API name: Normally we name it based on the Lambda function, for example `Camel`
      * Endpoint Type: Regional
2. Actions > Create Method > Any > "V"
   * Integration type: Lambda function
   * Use Lambda Proxy integration: "V"
   * Lambda Function: Camel
3. Actions > Deploy API
   * Deployment stage: New Stage > Stage name: "default" > "Deploy"
4. Copy the "Invoke URL". In this example it is `https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`

# Invoke (POST)
* `curl -s -X POST https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`
* `curl -s -X POST -d 'q=echo&p0=foo&p1=bar' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`
* `curl -s -X POST -d 'q=env' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`
* `curl -s -X POST -d 'q=wbsc' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`
* `curl -s -X POST -d 'q=wbc' https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default`

# Invoke (GET)
* `curl -s -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default'`
* `curl -s -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default?q=echo&p0=foo&p1=bar'`
* `curl -s -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default?q=env'`
* `curl -s -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default?q=wbsc'`
* `curl -s -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default?q=wbc'`

# Errors
* `curl -s -D - -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default?q=A&q=b'` => 400
* `curl -s -D - -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default?q=what'` => 404
* `curl -s -D - -X GET 'https://guz56zfyl4.execute-api.us-west-2.amazonaws.com/default?q=die'` => 500

# Client
`ikq echo foo bar` will be serialized as `q=echo&p0=foo&p1=bar` and will run `perl echo.pl foo bar` on AWS Lambda

# See Also
* [AWS::Lambda](https://metacpan.org/pod/AWS::Lambda)
* [AWS::XRay](https://metacpan.org/pod/AWS::XRay)

# License
```
"THE PEARL-TEA-WARE LICENSE", based on "THE BEER-WARE LICENSE":
<leeym@leeym.com> wrote this file. As long as you retain this notice you
can do whatever you want with this stuff. If we meet some day, and you think
this stuff is worth it, you can buy me a pearl tea in return. Yen-Ming Lee
```

# Author
Yen-Ming Lee `leeym@leeym.com`
