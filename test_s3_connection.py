import os
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

def create_bucket(client, bucket_name):
    """Create a bucket in DigitalOcean Spaces"""
    try:
        print(f"\nCreating bucket: {bucket_name}")
        
        # For DigitalOcean Spaces, we don't need to specify LocationConstraint
        client.create_bucket(Bucket=bucket_name)
        
        print(f"✅ Bucket '{bucket_name}' created successfully!")
        return True
        
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_message = e.response['Error']['Message']
        
        if error_code == 'BucketAlreadyExists':
            print(f"⚠️  Bucket '{bucket_name}' already exists")
        elif error_code == 'BucketAlreadyOwnedByYou':
            print(f"ℹ️  Bucket '{bucket_name}' already owned by you")
        else:
            print(f"❌ Error creating bucket ({error_code}): {error_message}")
        return False
    except Exception as e:
        print(f"❌ Unexpected error creating bucket: {str(e)}")
        return False

def test_s3_connection():
    try:
        # Create session and client
        session = boto3.session.Session()
        client = session.client('s3',
                                region_name='nyc3',
                                endpoint_url='https://keiretsu.nyc3.digitaloceanspaces.com',
                                aws_access_key_id="DO801H2JLD4WF442P2EF",
                                aws_secret_access_key="zjmezA7ned+kcGHAWKmjGA7s4wNi7s+vO8JPQ4hyl2I")
        
        print("Testing S3/DigitalOcean Spaces connection...")
        print(f"Endpoint: https://keiretsu.nyc3.digitaloceanspaces.com")
        print(f"Region: nyc3")
        
        # Test connection by listing buckets
        response = client.list_buckets()
        
        print("✅ Connection successful!")
        
        # Check if Buckets key exists in response
        if 'Buckets' in response:
            print(f"Found {len(response['Buckets'])} bucket(s):")
            for bucket in response['Buckets']:
                print(f"  - {bucket['Name']} (created: {bucket['CreationDate']})")
        else:
            print("No buckets found or unable to list buckets.")
            print(f"Response keys: {list(response.keys())}")
        
        # Create a test bucket
        bucket_name = "keiretsu-test-bucket"
        create_bucket(client, bucket_name)
        
        # List buckets again to verify creation
        print("\nListing buckets after creation:")
        response = client.list_buckets()
        if 'Buckets' in response:
            print(f"Found {len(response['Buckets'])} bucket(s):")
            for bucket in response['Buckets']:
                print(f"  - {bucket['Name']} (created: {bucket['CreationDate']})")
        else:
            print("Still no buckets found in response.")
            
        return True
        
    except NoCredentialsError:
        print("❌ Error: No credentials found or invalid credentials")
        return False
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_message = e.response['Error']['Message']
        print(f"❌ AWS Client Error ({error_code}): {error_message}")
        return False
    except Exception as e:
        print(f"❌ Unexpected error: {str(e)}")
        return False

if __name__ == "__main__":
    test_s3_connection()
