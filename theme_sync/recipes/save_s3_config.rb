# SAVE S3 CONFIG FILE

template '/home/deploy/.s3cfg' do
  source "s3cfg.erb"
  owner "deploy"
  mode "0600"
end

template '/root/.s3cfg' do
  source "s3cfg.erb"
  owner "root"
  mode "0600"
end